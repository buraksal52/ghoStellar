import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';

void main() {
  test('retains backend error and failing stage without continuing the action', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(signingOverlayProvider.notifier);
    var confirmed = false;

    await notifier.run((report) async {
      report(SigningStep.submitting);
      throw ApiException(
        code: 'cheque.bad_request',
        message: 'simulation failed: contract unavailable',
        httpStatus: 400,
      );
    });

    final state = container.read(signingOverlayProvider);
    expect(state.step, SigningStep.error);
    expect(state.errorDetails, contains('Stage: submitting'));
    expect(state.errorDetails, contains('Code: cheque.bad_request'));
    expect(state.errorDetails, contains('HTTP: 400'));
    expect(state.errorDetails, contains('simulation failed: contract unavailable'));

    notifier.dismiss();
    expect(container.read(signingOverlayProvider).errorDetails, isNull);
    await notifier.run((report) async { confirmed = true; });
    expect(confirmed, isTrue);
    expect(container.read(signingOverlayProvider).step, SigningStep.done);
    expect(container.read(signingOverlayProvider).errorDetails, isNull);
  });
}
