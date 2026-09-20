import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/pay_asset.dart';
import '../../core/utils/amount_formatter.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/starter_funds.dart';

/// Runs "Get test funds" behind the signing overlay — step labels while it
/// works, the amount that arrived when it's done, the reason if it failed
/// (the overlay's own error card). Returns whether it succeeded.
///
/// Shared by Settings, the Home balance card and the automatic first-run
/// offer so all three behave (and read) the same.
Future<bool> runStarterFunds(WidgetRef ref) async {
  final overlay = ref.read(signingOverlayProvider.notifier);
  final funds = ref.read(starterFundsProvider);

  final result = await overlay.run<StarterFundsResult>(
    (_) => funds.run(progress: (label) => overlay.setStep(SigningStep.preparing, label: label)),
  );
  if (result == null) return false;

  final added = result.usdcAdded;
  overlay.setStep(
    SigningStep.done,
    label: added == null
        ? 'Your wallet is ready'
        : 'Added ${AmountFormatter.trimTrailingZeros(added)} ${PayAsset.configured.label} to your wallet',
  );
  return true;
}
