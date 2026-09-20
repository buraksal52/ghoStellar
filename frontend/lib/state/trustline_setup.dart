import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/config/pay_asset.dart';
import '../core/errors/api_error.dart';
import '../data/api/models/tx_models.dart';
import 'anchor_providers.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'signing_overlay_provider.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

final trustlineSetupProvider = Provider((ref) => TrustlineSetup(ref));

/// Opens the app's asset trustline: unsigned XDR from the backend → signed on
/// this device → submitted by pay-tx-service → confirmed against the chain.
/// Shared by the "Set up" screen and the one-tap starter-funds flow.
///
/// Native XLM needs no trustline — every account already "holds" it — so both
/// methods are no-ops for a native deployment; nothing links here in that
/// case, but callers don't have to check first.
class TrustlineSetup {
  TrustlineSetup(this._ref);
  final Ref _ref;

  /// Throws [ApiException] on any failure (callers surface it, e.g. through
  /// the signing overlay). [report] is the overlay's step callback, if any.
  Future<void> run({void Function(SigningStep step)? report}) async {
    if (PayAsset.configured.isNative) return;
    // `primaryAnchorProvider` is only read here, never watched, so nothing has
    // necessarily loaded the anchor list yet — await it rather than failing.
    final anchor = _ref.read(primaryAnchorProvider) ?? (await _ref.read(anchorsProvider.future)).firstOrNull;
    final keyPair = _ref.read(walletProvider).keyPair;
    // Surface these instead of silently doing nothing.
    if (anchor == null) {
      throw ApiException(code: 'anchor.not_allowed', message: 'anchor not loaded');
    }
    if (keyPair == null) {
      throw ApiException(code: 'auth.invalid_token', message: 'wallet is locked');
    }
    final anchorApi = _ref.read(anchorApiProvider);
    final txApi = _ref.read(txApiProvider);
    final signing = _ref.read(stellarSigningServiceProvider);

    final xdr = await anchorApi.trustlineXdr(anchor.id);
    report?.call(SigningStep.signing);
    final signed = signing.signTransactionXdr(xdr, keyPair);
    report?.call(SigningStep.submitting);
    // Throws if the network rejected the transaction (see TxApi.submit).
    await txApi.submit(
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
  /// answers `anchor.trustline_missing` if it isn't there.
  Future<void> confirm() async {
    if (PayAsset.configured.isNative) return;
    final anchor = _ref.read(primaryAnchorProvider) ?? (await _ref.read(anchorsProvider.future)).firstOrNull;
    if (anchor == null) {
      throw ApiException(code: 'anchor.not_allowed', message: 'anchor not loaded');
    }
    await _ref.read(anchorApiProvider).trustlineConfirm(anchor.id);
    // Let a /sync that is still loading settle first, or its (older) answer
    // could land after the refresh below and hide the new trustline.
    try {
      await _ref.read(syncProvider.future);
    } catch (_) {
      // A failed first load is exactly what the refresh below retries.
    }
    await _ref.read(syncProvider.notifier).refresh();
    // A new trustline adds a USDC entry to the account's balances.
    _ref.invalidate(balancesProvider);
    final synced = _ref.read(syncProvider).value;
    if (synced != null && !synced.trustlineReady) {
      throw ApiException(code: 'anchor.trustline_missing', message: 'trustline not visible on-chain');
    }
  }
}
