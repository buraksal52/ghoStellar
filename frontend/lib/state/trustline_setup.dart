import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/errors/api_error.dart';
import '../data/api/models/tx_models.dart';
import 'anchor_providers.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'offline_providers.dart';
import 'signing_overlay_provider.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

final trustlineSetupProvider = Provider((ref) => TrustlineSetup(ref));

/// Opens the anchor's own asset trustline (`AnchorInfo.assetCode`/
/// `assetIssuer` — independent from the platform's [PayAsset.configured]):
/// unsigned XDR from the backend → signed on this device → submitted by
/// pay-tx-service → confirmed against the chain. Shared by the "Set up"
/// screen and the one-tap starter-funds flow.
///
/// A native anchor asset needs no trustline — every account already "holds"
/// it — so both methods are no-ops in that case; nothing links here then, but
/// callers don't have to check first.
class TrustlineSetup {
  TrustlineSetup(this._ref);
  final Ref _ref;

  /// Throws [ApiException] on any failure (callers surface it, e.g. through
  /// the signing overlay). [report] is the overlay's step callback, if any.
  Future<void> run({void Function(SigningStep step)? report}) async {
    // `primaryAnchorProvider` is only read here, never watched, so nothing has
    // necessarily loaded the anchor list yet — await it rather than failing.
    final anchor = _ref.read(primaryAnchorProvider) ?? (await _ref.read(anchorsProvider.future)).firstOrNull;
    final keyPair = _ref.read(walletProvider).keyPair;
    // Surface these instead of silently doing nothing.
    if (anchor == null) {
      throw ApiException(code: 'anchor.not_allowed', message: 'anchor not loaded');
    }
    if (anchor.assetIssuer.isEmpty) return;
    if (keyPair == null) {
      throw ApiException(code: 'auth.invalid_token', message: 'wallet is locked');
    }
    final anchorApi = _ref.read(anchorApiProvider);
    final chainSubmit = _ref.read(chainSubmitProvider);
    final signing = _ref.read(stellarSigningServiceProvider);

    final xdr = await anchorApi.trustlineXdr(anchor.id);
    report?.call(SigningStep.signing);
    final signed = signing.signTransactionXdr(xdr, keyPair);
    report?.call(SigningStep.submitting);
    // Throws if the network rejected the transaction (see TxApi.submit).
    await chainSubmit.submit(
      idempotencyKey: const Uuid().v4(),
      purpose: 'trustline',
      kind: TxKind.classic,
      xdr: signed,
    );
    report?.call(SigningStep.confirming);
    await confirm();
  }

  /// Once the trustline is on-chain (however it got there): have the backend
  /// check it and record it, then refresh what depends on it. The backend
  /// itself throws `anchor.trustline_missing` if it isn't there yet — this
  /// checks the anchor's own asset, never the platform's `/sync`
  /// `trustlineReady` (which is scoped to [PayAsset.configured]).
  Future<void> confirm() async {
    final anchor = _ref.read(primaryAnchorProvider) ?? (await _ref.read(anchorsProvider.future)).firstOrNull;
    if (anchor == null) {
      throw ApiException(code: 'anchor.not_allowed', message: 'anchor not loaded');
    }
    if (anchor.assetIssuer.isEmpty) return;
    await _ref.read(anchorApiProvider).trustlineConfirm(anchor.id);
    // Let a /sync that is still loading settle first, or its (older) answer
    // could land after the refresh below and hide other data it carries.
    try {
      await _ref.read(syncProvider.future);
    } catch (_) {
      // A failed first load is exactly what the refresh below retries.
    }
    await _ref.read(syncProvider.notifier).refresh();
    // An issued-asset trustline adds an entry to the account's balances.
    _ref.invalidate(balancesProvider);
  }
}
