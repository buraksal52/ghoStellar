import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/features/home/widgets/balance_card.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/home_providers.dart';
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
}) {
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      horizonReadServiceProvider.overrideWithValue(horizon),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [], trustlineReady: trustlineReady)),
      networkPassphraseProvider.overrideWithValue(passphrase),
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
  // The default deployment's one unit is native XLM: there is no trustline
  // and no separate fee balance to hide — the balance shown IS the fee
  // balance. See single_unit_test.dart for the asset-config contract itself.
  testWidgets('the balance is one number in one unit: XLM', (tester) async {
    final horizon = FakeHorizonReadService([
      FakeHorizonReadService.fundedBalances(native: '9999.9000000'),
    ]);
    await tester.pumpWidget(_app(horizon));
    await _settle(tester);

    expect(find.textContaining('9999.9 XLM', findRichText: true), findsOneWidget);
    expect(find.text('Network fee balance'), findsNothing);
    expect(find.text('Get test funds'), findsNothing);
  });

  group('testnet wallet with no funds', () {
    // Getting test funds lives in Settings (and runs once by itself for a new
    // wallet) — the Home card only ever shows the balance and hints.
    testWidgets('never offers a button of its own', (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService([AccountBalances.notFunded])));
      await _settle(tester);

      expect(find.text('Get test funds'), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('an unfunded wallet is pointed at Settings', (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService([AccountBalances.notFunded])));
      await _settle(tester);

      expect(find.text('Your wallet isn\'t funded yet — get test funds from Settings →'), findsOneWidget);
      expect(find.text('Get test funds'), findsNothing);
    });

    testWidgets('a native-asset wallet never shows the trustline hint', (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService(), trustlineReady: false));
      await _settle(tester);

      expect(find.textContaining('Set up'), findsNothing);
    });

    testWidgets('once funds arrive the balance follows', (tester) async {
      final horizon = FakeHorizonReadService([
        FakeHorizonReadService.fundedBalances(native: '0.0000000'),
        FakeHorizonReadService.fundedBalances(native: '7.0000000'),
      ]);
      await tester.pumpWidget(_app(horizon));
      await _settle(tester);
      expect(find.textContaining('0 XLM', findRichText: true), findsOneWidget);

      _container(tester).invalidate(balancesProvider);
      await _settle(tester);

      expect(find.textContaining('7 XLM', findRichText: true), findsOneWidget);
      expect(horizon.fetchCalls, 2);
    });
  });

  group('outside testnet the same hints apply', () {
    testWidgets('an unfunded wallet says so', (tester) async {
      await tester.pumpWidget(_app(FakeHorizonReadService([AccountBalances.notFunded]), passphrase: _public));
      await _settle(tester);

      expect(find.textContaining("isn't funded yet"), findsOneWidget);
    });
  });
}
