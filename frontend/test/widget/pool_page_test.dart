import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/features/pool/pool_page.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

/// A SyncNotifier whose `build()` never resolves until the test completes
/// it — lets a test see the widget in the same "pool balance not loaded
/// yet" state `_blocker` guards against.
class _DelayedSync extends SyncNotifier {
  final completer = Completer<SyncResponse>();

  @override
  Future<SyncResponse> build() => completer.future;
}

Widget _app({
  AccountBalances? balances,
  bool trustlineReady = true,
  String poolAmountRaw = '0',
}) {
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      horizonReadServiceProvider.overrideWithValue(
        FakeHorizonReadService([balances ?? FakeHorizonReadService.fundedBalances(native: '25.5000000')]),
      ),
      syncProvider.overrideWith(
        () => FakeSyncNotifier(const [], trustlineReady: trustlineReady, poolAmountRaw: poolAmountRaw),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: const Scaffold(body: PoolPage()),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

ElevatedButton _submitButton(WidgetTester tester) => tester.widget<ElevatedButton>(find.byType(ElevatedButton));

void main() {
  testWidgets('labels everything in XLM, the app\'s one asset', (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);

    // 25.5 XLM balance minus the 1.5 XLM native reserve headroom (mirrors
    // the backend's nativeReserveHeadroomRaw) = 24 spendable.
    expect(find.text('Available: 24 XLM'), findsOneWidget);
    expect(find.text('XLM'), findsWidgets);
  });

  testWidgets('a deposit within the balance is allowed', (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);

    await tester.enterText(find.byType(TextField), '10');
    await tester.pump();

    expect(_submitButton(tester).onPressed, isNotNull);
    expect(find.textContaining('Not enough XLM'), findsNothing);
  });

  testWidgets('a wallet with no funds is told why it cannot deposit', (tester) async {
    await tester.pumpWidget(_app(balances: FakeHorizonReadService.fundedBalances(native: '0.0000000')));
    await _settle(tester);

    await tester.enterText(find.byType(TextField), '10');
    await tester.pump();

    expect(find.text('You have no funds yet. Get test funds from Settings first.'), findsOneWidget);
    expect(find.text('Open Settings →'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);
  });

  testWidgets('an unfunded wallet is pointed at Settings', (tester) async {
    await tester.pumpWidget(_app(balances: AccountBalances.notFunded));
    await _settle(tester);

    expect(find.textContaining("isn't funded yet"), findsOneWidget);
    expect(find.text('Open Settings →'), findsOneWidget);
  });

  testWidgets('depositing more than the spendable balance is blocked with that amount in the message', (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);

    // 25.5 XLM balance minus the 1.5 XLM native reserve headroom = 24
    // spendable — depositing the full raw balance must still be blocked,
    // since Stellar's own reserve makes it undepositable.
    await tester.enterText(find.byType(TextField), '25.5');
    await tester.pump();

    expect(find.text('Not enough XLM — you have 24.'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '24');
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('withdraw is checked against the pool balance and shows it as the available amount', (tester) async {
    await tester.pumpWidget(_app(poolAmountRaw: '100000000')); // 10 XLM in the pool
    await _settle(tester);

    await tester.tap(find.text('Withdraw').first);
    await tester.pump();

    expect(find.text('In pool: 10 XLM'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '10.5');
    await tester.pump();
    expect(find.text('That is more than your pool balance.'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '10');
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('withdraw with an empty pool says so instead of failing in simulation', (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);

    await tester.tap(find.text('Withdraw').first);
    await tester.pump();

    expect(find.text('You have nothing in the pool to withdraw yet.'), findsOneWidget);
  });

  testWidgets('withdraw is blocked, not silently allowed, while the pool balance is still loading', (tester) async {
    final sync = _DelayedSync();
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
        horizonReadServiceProvider.overrideWithValue(
          FakeHorizonReadService([FakeHorizonReadService.fundedBalances(native: '25.5000000')]),
        ),
        syncProvider.overrideWith(() => sync),
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        home: const Scaffold(body: PoolPage()),
      ),
    ));
    // One pump: the wallet balance resolves, the pool sync deliberately
    // does not — pool == null the way it looks before the first /sync
    // response ever lands.
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Withdraw').first);
    await tester.pump();

    expect(find.text('Your pool balance is still loading — try again in a moment.'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);

    sync.completer.complete(syncResponse(const []));
  });

  testWidgets('withdraw is blocked when there is not enough native XLM left to pay the network fee', (tester) async {
    await tester.pumpWidget(_app(
      balances: FakeHorizonReadService.fundedBalances(native: '1.0000000'), // below the 1.5 XLM headroom
      poolAmountRaw: '100000000', // 10 XLM in the pool — plenty to withdraw from
    ));
    await _settle(tester);

    await tester.tap(find.text('Withdraw').first);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '5');
    await tester.pump();

    expect(find.text('You need a little XLM in your wallet to cover the network fee.'), findsOneWidget);
    expect(find.text('Open Settings →'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);
  });
}
