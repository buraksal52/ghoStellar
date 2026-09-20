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

Widget _app(FakeHorizonReadService horizon, {bool trustlineReady = true}) {
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      horizonReadServiceProvider.overrideWithValue(horizon),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [], trustlineReady: trustlineReady)),
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

void main() {
  testWidgets('the headline number is the USDC balance; XLM is the network fee balance', (tester) async {
    final horizon = FakeHorizonReadService([
      FakeHorizonReadService.fundedBalances(native: '9999.9000000', other: {'USDC': '42.5000000'}),
    ]);
    await tester.pumpWidget(_app(horizon));
    await _settle(tester);

    expect(find.textContaining('42.5 USDC', findRichText: true), findsOneWidget);
    expect(find.text('Network fee balance'), findsOneWidget);
    expect(find.text('9999.9 XLM'), findsOneWidget);
  });

  testWidgets('a funded wallet without USDC reads 0 USDC and offers the trustline setup', (tester) async {
    await tester.pumpWidget(_app(FakeHorizonReadService(), trustlineReady: false));
    await _settle(tester);

    expect(find.textContaining('0 USDC', findRichText: true), findsOneWidget);
    expect(find.text('Set up USDC to receive funds →'), findsOneWidget);
    // The 10000 XLM must NOT be presented as the spendable headline balance:
    // it appears only in the fee line.
    expect(find.text('10000 XLM'), findsOneWidget);
    expect(find.textContaining('10000 USDC', findRichText: true), findsNothing);
  });

  testWidgets('an unfunded wallet says so rather than showing a bare zero', (tester) async {
    await tester.pumpWidget(_app(FakeHorizonReadService([AccountBalances.notFunded])));
    await _settle(tester);

    expect(find.textContaining("isn't funded yet"), findsOneWidget);
    expect(find.text('Network fee balance'), findsNothing);
  });

  testWidgets('invalidating the provider makes the card show money that arrived later', (tester) async {
    final horizon = FakeHorizonReadService([
      AccountBalances.notFunded,
      FakeHorizonReadService.fundedBalances(other: {'USDC': '7.0000000'}),
    ]);
    await tester.pumpWidget(_app(horizon));
    await _settle(tester);
    expect(find.textContaining("isn't funded yet"), findsOneWidget);

    ProviderScope.containerOf(tester.element(find.byType(BalanceCard))).invalidate(balancesProvider);
    await _settle(tester);

    expect(find.textContaining("isn't funded yet"), findsNothing);
    expect(find.textContaining('7 USDC', findRichText: true), findsOneWidget);
    expect(horizon.fetchCalls, 2);
  });
}
