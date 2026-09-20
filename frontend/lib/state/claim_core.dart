import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' show KeyPair;
import 'package:uuid/uuid.dart';

import '../core/errors/api_error.dart';
import '../data/api/models/tx_models.dart';
import 'core_providers.dart';
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

/// Whether a failed [performClaim] is worth retrying later, or the cheque
/// itself can never succeed (expired / already resolved / not found).
ClaimOutcome classifyClaimFailure(Object error) {
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
  final txApi = ref.read(txApiProvider);
  final signing = ref.read(stellarSigningServiceProvider);

  final claimXdr = await chequeApi.claimXdr(chequeId);
  onStep?.call(SigningStep.signing);
  final signed = signing.signTransactionXdr(claimXdr, keyPair);
  onStep?.call(SigningStep.submitting);
  final result = await txApi.submit(
    idempotencyKey: const Uuid().v4(),
    purpose: 'cheque_claim',
    kind: TxKind.soroban,
    xdr: signed,
  );
  onStep?.call(SigningStep.confirming);
  await chequeApi.confirmClaim(chequeId, result.hash);
  await chequeApi.ack(chequeId);
  await ref.read(syncProvider.notifier).refresh();
}
