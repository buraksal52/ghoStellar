import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_error.dart';
import '../core/errors/error_copy.dart';

enum SigningStep { idle, preparing, signing, submitting, confirming, done, error }

class SigningOverlayState {
  const SigningOverlayState({this.step = SigningStep.idle, this.errorMessage});

  final SigningStep step;
  final String? errorMessage;

  static const idle = SigningOverlayState();
}

/// Drives the signing-lifecycle modal off the REAL async state of whichever
/// flow is running (create → sign → submit → confirm), never a fixed timer.
/// Each feature (Send/Receive/Pool/Anchor/Trustline) calls [run] with a
/// callback that reports its own steps via the passed-in [SigningRunner].
class SigningOverlayNotifier extends Notifier<SigningOverlayState> {
  @override
  SigningOverlayState build() => SigningOverlayState.idle;

  void setStep(SigningStep step) {
    state = SigningOverlayState(step: step);
  }

  Future<T?> run<T>(Future<T> Function(void Function(SigningStep) report) action) async {
    setStep(SigningStep.preparing);
    try {
      final result = await action(setStep);
      setStep(SigningStep.done);
      return result;
    } on ApiException catch (e) {
      state = SigningOverlayState(step: SigningStep.error, errorMessage: ErrorCopy.forException(e));
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
