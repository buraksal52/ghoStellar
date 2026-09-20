import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/error_copy.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/features/home/widgets/balance_card.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/home_providers.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';
import 'package:ghostellar_app/state/starter_funds.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _testnet = 'Test SDF Network ; September 2015';
const _public = 'Public Global Stellar Network ; September 2015';

Widget _app(
  FakeHorizonReadService horizon, {
  bool trustlineReady = true,
  String passphrase = _testnet,
  FakeStarterFunds? funds,
}) {
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      horizonReadServiceProvider.overrideWithValue(horizon),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [], trustlineReady: trustlineReady)),
      networkPassphraseProvider.overrideWithValue(passphrase),
      starterFundsProvider.overrideWithValue(funds ?? FakeStarterFunds()),
    ],
    child: MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: const Scaffold(body: BalanceCard()),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(BalanceCard)));

void main() {
  testWidgets('the balance is one number in one unit: USDC — XLM is never shown', (tester) async {
    final horizon = FakeHorizonReadService([
      FakeHorizonReadService.fundedBalances(native: '9999.9000000', other: {'USDC': '42.5000000'}),
    ]);
    await tester.pumpWidget(_app(horizon));
    await _settle(tester);

    expect(find.textContaining('42.5 USDC', findRichText: true), findsOneWidget);
    expect(find.textContaining('XLM', findRichText: true), findsNothing);
    expect(find.textContaining('9999'), findsNothing);
    expect(find.text('Network fee balance'), findsNothing);
    expect(find.text('Get test funds'), findsNothing, reason: 'a wallet that holds USDC needs no starter funds');
  });

  group('testnet wallet with no USDC', () {
    testWidgets('a funded wallet without USDC is offered "Get test funds" — and never shows the faucet XLM',
        (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService(), trustlineReady: false));
      await _settle(tester);

      expect(find.textContaining('0 USDC', findRichText: true), findsOneWidget);
      expect(find.text('Get test funds'), findsOneWidget);
      // One clear action instead of two hints to work out.
      expect(find.text('Set up USDC to receive funds →'), findsNothing);
      expect(find.textContaining('10000', findRichText: true), findsNothing);
      expect(find.textContaining('XLM', findRichText: true), findsNothing);
    });

    testWidgets('an unfunded wallet gets the same single button', (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService([AccountBalances.notFunded])));
      await _settle(tester);

      expect(find.text('Get test funds'), findsOneWidget);
      expect(find.textContaining("isn't funded yet"), findsNothing);
    });

    testWidgets('tapping it runs the flow and announces what arrived', (tester) async {
      final funds = FakeStarterFunds()..usdcAdded = '24.1000000';
      await tester.pumpWidget(_app(FakeHorizonReadService(), funds: funds));
      await _settle(tester);

      await tester.tap(find.text('Get test funds'));
      await _settle(tester);

      expect(funds.runs, 1);
      final overlay = _container(tester).read(signingOverlayProvider);
      expect(overlay.step, SigningStep.done);
      expect(overlay.label, 'Added 24.1 USDC to your wallet');
    });

    testWidgets('a failure is explained, and the button is still there to try again', (tester) async {
      final funds = FakeStarterFunds()..error = apiError('anchor.deposit_failed');
      await tester.pumpWidget(_app(FakeHorizonReadService(), funds: funds));
      await _settle(tester);

      await tester.tap(find.text('Get test funds'));
      await _settle(tester);

      expect(_container(tester).read(signingOverlayProvider).errorMessage, ErrorCopy.forCode('anchor.deposit_failed'));
      expect(find.text('Get test funds'), findsOneWidget);
    });

    testWidgets('once USDC arrives the button goes away', (tester) async {
      final horizon = FakeHorizonReadService([
        FakeHorizonReadService.fundedBalances(),
        FakeHorizonReadService.fundedBalances(other: {'USDC': '7.0000000'}),
      ]);
      await tester.pumpWidget(_app(horizon));
      await _settle(tester);
      expect(find.text('Get test funds'), findsOneWidget);

      _container(tester).invalidate(balancesProvider);
      await _settle(tester);

      expect(find.text('Get test funds'), findsNothing);
      expect(find.textContaining('7 USDC', findRichText: true), findsOneWidget);
      expect(horizon.fetchCalls, 2);
    });
  });

  group('outside testnet there is no faucet, only hints', () {
    testWidgets('an unfunded wallet says so', (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService([AccountBalances.notFunded]), passphrase: _public));
      await _settle(tester);

      expect(find.textContaining("isn't funded yet"), findsOneWidget);
      expect(find.text('Get test funds'), findsNothing);
      expect(find.textContaining('XLM', findRichText: true), findsNothing);
    });

    testWidgets('a wallet without a trustline is pointed at the USDC setup', (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService(), trustlineReady: false, passphrase: _public));
      await _settle(tester);

      expect(find.text('Set up USDC to receive funds →'), findsOneWidget);
      expect(find.text('Get test funds'), findsNothing);
    });
  });

  group('network fee balance (never shown as an amount)', () {
    testWidgets('a low one raises a unit-less hint', (tester) async {
      final horizon = FakeHorizonReadService([
        FakeHorizonReadService.fundedBalances(native: '1.5000000', other: {'USDC': '5.0000000'}),
      ]);
      await tester.pumpWidget(_app(horizon));
      await _settle(tester);

      expect(find.text('Your network fee balance is low — get test funds from Settings →'), findsOneWidget);
      expect(find.textContaining('XLM', findRichText: true), findsNothing);
      expect(find.textContaining('1.5', findRichText: true), findsNothing);
    });

    testWidgets('a healthy one shows nothing at all', (tester) async {
      final horizon = FakeHorizonReadService([
        FakeHorizonReadService.fundedBalances(native: '2.0000000', other: {'USDC': '5.0000000'}),
      ]);
      await tester.pumpWidget(_app(horizon));
      await _settle(tester);

      expect(find.textContaining('network fee'), findsNothing);
    });
  });
}
