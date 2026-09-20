import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_error.dart';
import '../core/errors/error_copy.dart';

enum SigningStep { idle, preparing, signing, submitting, confirming, done, error }

class SigningOverlayState {
  const SigningOverlayState({this.step = SigningStep.idle, this.errorMessage, this.errorDetails, this.label});

  final SigningStep step;
  final String? errorMessage;
  final String? errorDetails;

  /// Replaces the step's stock wording (e.g. "Enabling USDC…" for a
  /// multi-step flow, or "Added 24.1 USDC" on completion).
  final String? label;

  static const idle = SigningOverlayState();
}

/// Drives the signing-lifecycle modal off the REAL async state of whichever
/// flow is running (create → sign → submit → confirm), never a fixed timer.
/// Each feature (Send/Receive/Pool/Anchor/Trustline) calls [run] with a
/// callback that reports its own steps via the passed-in [SigningRunner].
class SigningOverlayNotifier extends Notifier<SigningOverlayState> {
  @override
  SigningOverlayState build() => SigningOverlayState.idle;

  void setStep(SigningStep step, {String? label}) {
    state = SigningOverlayState(step: step, label: label);
  }

  Future<T?> run<T>(Future<T> Function(void Function(SigningStep) report) action) async {
    setStep(SigningStep.preparing);
    try {
      final result = await action(setStep);
      setStep(SigningStep.done);
      return result;
    } on ApiException catch (e) {
      state = SigningOverlayState(
        step: SigningStep.error,
        errorMessage: ErrorCopy.forException(e),
        errorDetails: 'Stage: ${state.step.name}\nCode: ${e.code}\n'
            'HTTP: ${e.httpStatus ?? "unknown"}\nMessage: ${e.message}',
      );
      return null;
    } catch (e) {
      state = SigningOverlayState(step: SigningStep.error, errorMessage: e.toString());
      return null;
    }
  }

  void dismiss() {
    state = SigningOverlayState.idle;
  }
}

final signingOverlayProvider =
    NotifierProvider<SigningOverlayNotifier, SigningOverlayState>(
  SigningOverlayNotifier.new,
);
