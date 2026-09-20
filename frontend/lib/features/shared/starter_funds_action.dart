import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/pay_asset.dart';
import '../../core/utils/amount_formatter.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/starter_funds.dart';

/// Runs "Get test funds" behind the signing overlay — step labels while it
/// works, the amount that arrived when it's done, the reason if it failed
/// (the overlay's own error card). Returns whether it succeeded.
///
/// The wait for the bank is a "Continue in background" step: dismissing the
/// overlay leaves the flow running (no further step labels pop the overlay
/// back up); the result, good or bad, still shows when it arrives.
///
/// Shared by Settings and the automatic first-run offer so both behave (and
/// read) the same.
Future<bool> runStarterFunds(WidgetRef ref) async {
  final overlay = ref.read(signingOverlayProvider.notifier);
  final funds = ref.read(starterFundsProvider);

  var background = false;
  var silenced = false;
  var current = '';
  void show(String label) {
    current = label;
    // Once the user has dismissed the wait, the flow carries on silently.
    if (background && (silenced || overlay.isIdle)) {
      silenced = true;
      return;
    }
    overlay.setStep(SigningStep.preparing, label: label, dismissible: background);
  }

  final result = await overlay.run<StarterFundsResult>(
    (_) => funds.run(
      progress: show,
      canContinueInBackground: () {
        background = true;
        show(current);
      },
    ),
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
