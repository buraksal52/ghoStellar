import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/error_copy.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/features/settings/settings_page.dart';
import 'package:ghostellar_app/state/auth_providers.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';
import 'package:ghostellar_app/state/starter_funds.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _testnet = 'Test SDF Network ; September 2015';
const _public = 'Public Global Stellar Network ; September 2015';

class _NoOpAuth extends AuthNotifier {
  @override
  Future<bool> build() async => true;
}

Widget _app(FakeStarterFunds funds, {String networkPassphrase = _testnet}) {
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      starterFundsProvider.overrideWithValue(funds),
      authProvider.overrideWith(_NoOpAuth.new),
      networkPassphraseProvider.overrideWithValue(networkPassphrase),
    ],
    child: MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: const Scaffold(body: SettingsPage()),
    ),
  );
}

SigningOverlayState _overlay(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SettingsPage))).read(signingOverlayProvider);

Future<void> _tapFund(WidgetTester tester) async {
  await tester.tap(find.text('Get test funds'));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('the button is shown on testnet and runs the whole starter-funds flow once', (tester) async {
    final funds = FakeStarterFunds();
    await tester.pumpWidget(_app(funds));

    expect(find.text('Get test funds'), findsOneWidget);
    await _tapFund(tester);

    expect(funds.runs, 1);
  });

  testWidgets('what arrived is announced in the one unit the app has: USDC', (tester) async {
    await tester.pumpWidget(_app(FakeStarterFunds()..usdcAdded = '24.1000000'));

    await _tapFund(tester);

    final overlay = _overlay(tester);
    expect(overlay.step, SigningStep.done);
    expect(overlay.label, 'Added 24.1 USDC to your wallet');
    expect(overlay.label, isNot(contains('XLM')));
  });

  testWidgets('the overlay shows the step the flow is on while it works', (tester) async {
    final funds = FakeStarterFunds()..delay = const Duration(milliseconds: 200);
    await tester.pumpWidget(_app(funds));

    await tester.tap(find.text('Get test funds'));
    await tester.pump();
    await tester.pump();

    expect(_overlay(tester).step, isNot(SigningStep.done));
    expect(_overlay(tester).label, 'Preparing your wallet…');

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
  });

  testWidgets('a step that fails is explained in plain words on the overlay', (tester) async {
    await tester.pumpWidget(_app(FakeStarterFunds()..error = apiError('anchor.deposit_failed')));

    await _tapFund(tester);

    final overlay = _overlay(tester);
    expect(overlay.step, SigningStep.error);
    expect(overlay.errorMessage, ErrorCopy.forCode('anchor.deposit_failed'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bank deposit that is still pending points at the Bank tab, not at the wallet', (tester) async {
    await tester.pumpWidget(_app(FakeStarterFunds()..error = apiError('anchor.deposit_pending')));

    await _tapFund(tester);

    expect(_overlay(tester).errorMessage, contains('Bank tab'));
  });

  testWidgets('the button is hidden on a non-testnet network', (tester) async {
    final funds = FakeStarterFunds();
    await tester.pumpWidget(_app(funds, networkPassphrase: _public));

    expect(find.text('Get test funds'), findsNothing);
    expect(funds.runs, 0);
  });

  testWidgets('a second tap while the flow is in progress is ignored', (tester) async {
    final funds = FakeStarterFunds()..delay = const Duration(milliseconds: 200);
    await tester.pumpWidget(_app(funds));

    await tester.tap(find.text('Get test funds'));
    await tester.pump(); // rebuild with the row disabled, still in flight
    await tester.tap(find.text('Get test funds'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(funds.runs, 1);
  });

  testWidgets('the row works again once the flow has finished (or failed)', (tester) async {
    final funds = FakeStarterFunds()..error = apiError('anchor.deposit_failed');
    await tester.pumpWidget(_app(funds));

    await _tapFund(tester);
    funds.error = null;
    await _tapFund(tester);

    expect(funds.runs, 2);
  });
}
