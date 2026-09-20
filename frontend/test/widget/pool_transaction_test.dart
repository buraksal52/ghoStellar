import "package:ghostellar_app/data/api/models/cheque_models.dart";

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/api/endpoints/pool_api.dart';
import 'package:ghostellar_app/data/api/endpoints/tx_api.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/data/storage/local_activity_log.dart';
import 'package:ghostellar_app/features/pool/pool_page.dart';
import 'package:ghostellar_app/state/connectivity_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/home_providers.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';
import '../support/fakes.dart';

class _Pool extends Fake implements PoolApi {
  _Pool({this.confirmError});
  final Object? confirmError;
  final confirmed = <String>[];
  @override
  Future<String> depositXdr(String amount) async => 'deposit';
  @override
  Future<String> withdrawXdr(String amount) async => 'withdraw';
  @override
  Future<void> confirmDeposit({
    required String amount,
    required int ledgerSeq,
  }) async {
    if (confirmError != null) throw confirmError!;
    confirmed.add('deposit');
  }

  @override
  Future<void> confirmWithdraw({required String amount}) async {
    if (confirmError != null) throw confirmError!;
    confirmed.add('withdraw');
  }
}

class _Tx extends Fake implements TxApi {
  _Tx(this.result);
  final SubmitResponse result;
  @override
  Future<SubmitResponse> submit({
    required String idempotencyKey,
    required String purpose,
    required TxKind kind,
    required String xdr,
  }) async => result;
}

class _Sync extends FakeSyncNotifier {
  _Sync() : super([]);
  @override
  Future<SyncResponse> build() async {
    final response = syncResponse([]);
    return response.copyWith(
      pool: response.pool.copyWith(amountRaw: '200000000'),
    );
  }
}

class _MissingTrustlineSync extends FakeSyncNotifier {
  _MissingTrustlineSync() : super([]);

  @override
  Future<SyncResponse> build() async =>
      syncResponse([]).copyWith(trustlineReady: false);
}

void main() {
  testWidgets('native deposits do not require a trustline', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith(_MissingTrustlineSync.new),
          balancesProvider.overrideWith(
            (ref) async => const AccountBalances(native: '999', other: {}),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          home: const Scaffold(body: PoolPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '25');
    await tester.pump();
    expect(find.textContaining('Set up'), findsNothing);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed, isNotNull);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final withdraw in [false, true]) {
    for (final resultCode in ['SUCCESS', 'tx_failed', 'PENDING']) {
      testWidgets('${withdraw ? 'withdraw' : 'deposit'}: $resultCode', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final pool = _Pool();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              poolApiProvider.overrideWithValue(pool),
              txApiProvider.overrideWithValue(
                _Tx(
                  SubmitResponse(
                    hash: 'hash',
                    successful: resultCode == 'SUCCESS',
                    resultCode: resultCode,
                    replayed: false,
                  ),
                ),
              ),
              walletProvider.overrideWith(
                () => UnlockedWallet(KeyPair.random()),
              ),
              stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
              syncProvider.overrideWith(_Sync.new),
              balancesProvider.overrideWith(
                (ref) async =>
                    const AccountBalances(native: '999', other: {'USDC': '12'}),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(extensions: [AppColors.light]),
              home: const Scaffold(body: PoolPage()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 999 XLM balance minus the 1.5 XLM native reserve headroom
        // (mirrors the backend's nativeReserveHeadroomRaw) = 997.5 spendable.
        expect(find.text('Available: 997.5 XLM'), findsOneWidget);
        expect(find.text('USDC'), findsNothing);
        if (withdraw) {
          await tester.tap(find.text('Withdraw').first);
          await tester.pumpAndSettle();
          expect(find.textContaining('In pool: 20'), findsOneWidget);
        }
        await tester.enterText(find.byType(TextField), '2');
        await tester.pump();
        await tester.tap(find.byType(ElevatedButton));
        await tester.pumpAndSettle();
        final success = resultCode == 'SUCCESS';
        expect(
          pool.confirmed,
          success ? [withdraw ? 'withdraw' : 'deposit'] : isEmpty,
        );
        final events = await LocalActivityLog().readAll();
        expect(events.length, success ? 1 : 0);
        // The pool is always in the platform's one asset — no asset code is
        // stored per event any more; it's derived at read time instead.
        if (success) expect(events.single.kind, withdraw ? 'pool_withdraw' : 'pool_deposit');
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PoolPage)),
        );
        expect(
          container.read(signingOverlayProvider).step,
          success ? SigningStep.done : SigningStep.error,
        );
        if (!success) {
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '2',
          );
        }
      });
    }
  }

  Widget poolApp(_Pool pool) => ProviderScope(
        overrides: [
          poolApiProvider.overrideWithValue(pool),
          txApiProvider.overrideWithValue(
            _Tx(const SubmitResponse(hash: 'hash', successful: true, resultCode: 'SUCCESS', replayed: false)),
          ),
          walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
          stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
          syncProvider.overrideWith(_Sync.new),
          balancesProvider.overrideWith(
            (ref) async => const AccountBalances(native: '999', other: {'USDC': '12'}),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          home: const Scaffold(body: PoolPage()),
        ),
      );

  for (final withdraw in [false, true]) {
    testWidgets(
      '${withdraw ? 'withdraw' : 'deposit'}: a failed backend confirmation after the on-chain move is not shown as a failure',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final pool = _Pool(confirmError: StateError('confirm unavailable'));
        await tester.pumpWidget(poolApp(pool));
        await tester.pumpAndSettle();
        if (withdraw) {
          await tester.tap(find.text('Withdraw').first);
          await tester.pumpAndSettle();
        }
        await tester.enterText(find.byType(TextField), '2');
        await tester.pump();
        await tester.tap(find.byType(ElevatedButton));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(tester.element(find.byType(PoolPage)));
        // The money already moved: success, the move is logged, and the
        // amount is cleared so a second tap can't move it twice.
        expect(container.read(signingOverlayProvider).step, SigningStep.done);
        final events = await LocalActivityLog().readAll();
        expect(events.single.kind, withdraw ? 'pool_withdraw' : 'pool_deposit');
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      },
    );
  }

  testWidgets('offline: the pool says it needs a connection and the button is disabled', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(poolApp(_Pool()));
    await tester.pumpAndSettle();
    ProviderScope.containerOf(tester.element(find.byType(PoolPage)))
        .read(offlineModeProvider.notifier)
        .markOffline();
    await tester.enterText(find.byType(TextField), '2');
    await tester.pumpAndSettle();

    expect(find.textContaining('needs a connection'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed, isNull);
  });
}
