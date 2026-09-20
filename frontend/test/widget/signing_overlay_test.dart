import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/features/shared/widgets/signing_overlay.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';

Widget _app() => ProviderScope(
      child: MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        home: const Scaffold(body: Stack(children: [SigningOverlay()])),
      ),
    );

SigningOverlayNotifier _overlay(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SigningOverlay))).read(signingOverlayProvider.notifier);

void main() {
  testWidgets('an ordinary step has no way out — the flow is short', (tester) async {
    await tester.pumpWidget(_app());
    _overlay(tester).setStep(SigningStep.signing);
    await tester.pump();

    expect(find.text('Waiting for signature…'), findsOneWidget);
    expect(find.text('Continue in background'), findsNothing);
  });

  testWidgets('a long wait can be left: the button closes the overlay', (tester) async {
    await tester.pumpWidget(_app());
    _overlay(tester).setStep(SigningStep.preparing, label: 'Waiting for the bank…', dismissible: true);
    await tester.pump();

    expect(find.text('Waiting for the bank…'), findsOneWidget);
    await tester.tap(find.text('Continue in background'));
    await tester.pump();

    expect(find.text('Waiting for the bank…'), findsNothing);
    expect(_overlay(tester).isIdle, isTrue);
  });

  testWidgets('the outcome card has no such button', (tester) async {
    await tester.pumpWidget(_app());
    _overlay(tester).setStep(SigningStep.done, label: 'Added 24.1 USDC to your wallet');
    await tester.pump();

    expect(find.text('Continue in background'), findsNothing);
    expect(find.text('Done'), findsOneWidget);
  });
}
