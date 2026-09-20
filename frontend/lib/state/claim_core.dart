import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' show KeyPair;
import 'package:uuid/uuid.dart';

import '../core/errors/api_error.dart';
import '../data/api/endpoints/cheque_api.dart';
import '../data/api/models/tx_models.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'offline_providers.dart';
import 'signing_overlay_provider.dart';
import 'sync_providers.dart';

/// Whether a failed claim is worth retrying later, or the cheque itself is
/// done for and should be dropped instead of retried forever. Used by
/// callers that retry silently (`inbox_providers.dart`) — a caller showing
/// the error to a person (the signing overlay) just displays it instead.
enum ClaimOutcome { success, retryLater, gone }

const _terminalClaimCodes = {
  'cheque.expired',
  'cheque.not_found',
  'cheque.terminal_state',
};

/// `cheque.not_funded`: the backend read the chain and the cheque isn't
/// `Funded` there yet (the sender's lock transaction may still be
/// confirming) — a "not yet", not a permanent refusal, so it must retry
/// like any other transient failure rather than being dropped as `gone`.
const _notYetFundedCode = 'cheque.not_funded';

/// Whether a failed [performClaim] is worth retrying later, or the cheque
/// itself can never succeed (expired / already resolved / not found).
///
/// `cheque.already_claimed` never reaches here: [performClaim] itself
/// treats it as success (see below), since it means an EARLIER attempt's
/// on-chain claim succeeded and only the follow-up confirm/ack was lost.
ClaimOutcome classifyClaimFailure(Object error) {
  if (error is ApiException && error.code == _notYetFundedCode) {
    return ClaimOutcome.retryLater;
  }
  if (error is ApiException && _terminalClaimCodes.contains(error.code)) {
    return ClaimOutcome.gone;
  }
  return ClaimOutcome.retryLater;
}

/// The one place that does claim-xdr → sign → submit → confirm → ack →
/// refresh. [onStep] is optional so a silent background retry doesn't need a
/// UI to report to. Throws on failure — [classifyClaimFailure] says why.
Future<void> performClaim(
  Ref ref,
  KeyPair keyPair,
  String chequeId, {
  void Function(SigningStep)? onStep,
}) async {
  final chequeApi = ref.read(chequeApiProvider);
  final chainSubmit = ref.read(chainSubmitProvider);
  final signing = ref.read(stellarSigningServiceProvider);

  String claimXdr;
  try {
    claimXdr = await chequeApi.claimXdr(chequeId);
  } on ApiException catch (e) {
    if (e.code == 'cheque.already_claimed') {
      // An earlier attempt's on-chain claim already succeeded (the backend
      // re-derived this from the contract's own get_cheque and repaired the
      // local row) — this attempt's job is done, just close out the ledger.
      await _tryAck(chequeApi, chequeId);
      await ref.read(syncProvider.notifier).refresh();
      ref.invalidate(balancesProvider);
      return;
    }
    rethrow;
  }
  onStep?.call(SigningStep.signing);
  final signed = signing.signTransactionXdr(claimXdr, keyPair);
  onStep?.call(SigningStep.submitting);
  final result = await chainSubmit.submit(
    idempotencyKey: const Uuid().v4(),
    purpose: 'cheque_claim',
    kind: TxKind.soroban,
    xdr: signed,
  );
  // A Soroban submit that came back PENDING (not yet confirmed by the
  // network) is not a failure (see TxApi.submit), but it is also not yet a
  // confirmed claim — confirming it now would mark the cheque TALEP_EDILDI
  // on a hash that might still fail on chain. Leave it for a later retry,
  // which will either see `cheque.already_claimed` (it landed) or the same
  // `PENDING` again.
  if (!result.successful && result.resultCode == 'PENDING') {
    throw ApiException(code: 'tx.pending', message: result.hash);
  }
  onStep?.call(SigningStep.confirming);
  await chequeApi.confirmClaim(chequeId, result.hash);
  await _tryAck(chequeApi, chequeId);
  await ref.read(syncProvider.notifier).refresh();
  ref.invalidate(balancesProvider);
}

/// `ack` is a ledger-closing courtesy (TALEP_EDILDI → ONAYLANDI/KAPANDI):
/// the money already moved by the time it's called, so a failure here must
/// never make [performClaim] look like it failed and retry the whole claim
/// from scratch (which would hit `cheque.already_claimed` anyway, but
/// needlessly).
Future<void> _tryAck(ChequeApi chequeApi, String chequeId) async {
  try {
    await chequeApi.ack(chequeId);
  } catch (_) {
    // Best-effort; a later /sync-driven retry or manual visit can still ack.
  }
}
