import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/api/endpoints/anchor_api.dart';
import 'package:ghostellar_app/data/api/models/anchor_models.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/data/api/endpoints/tx_api.dart';
import 'package:ghostellar_app/data/api/models/sep6_models.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/features/anchor/anchor_deposit_withdraw_page.dart';
import 'package:ghostellar_app/state/anchor_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/home_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' hide AnchorTransaction;

const _anchor = AnchorInfo(
  id: 'default',
  domain: 'tr-mock-anchor.fly.dev',
  signingKey: 'GSIGNING',
  webAuthEndpoint: 'https://tr-mock-anchor.fly.dev/auth',
  assetCode: 'USDC',
  assetIssuer: 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5',
);

class _FakeAnchorApi extends Fake implements AnchorApi {
  String status = 'pending_user_transfer_start';
  String? amountOut;
  Object? depositError;

  /// What the backend's anchor ledger lists (`GET /anchors/{id}/transactions`).
  List<AnchorTransaction> ledger = const [];

  /// Thrown by [sep6Transaction] when set — an anchor that cannot be reached.
  Object? statusError;
  final statusChecks = <String>[];
  var ledgerFetches = 0;
  final reports = <Map<String, Object?>>[];
  final depositCalls = <Map<String, String>>[];

  @override
  Future<Sep6Deposit> sep6Deposit(String anchorId, String anchorToken,
      {required String assetCode, required String amount}) async {
    depositCalls.add({'token': anchorToken, 'asset': assetCode, 'amount': amount});
    if (depositError != null) throw depositError!;
    return Sep6Deposit.fromJson({
      'id': 'sep_1',
      'how': 'wire it',
      'instructions': {
        'bank_account_number': {'value': 'TR050009900000000000000001'},
        'external_transfer_memo': {'value': 'TRMA-A9LA-MULF'},
      },
    });
  }

  @override
  Future<Sep6Transaction> sep6Transaction(String anchorId, String anchorToken, String txId) async {
    statusChecks.add(txId);
    if (statusError != null) throw statusError!;
    return Sep6Transaction(id: txId, status: status, amountIn: '100.00', amountOut: amountOut);
  }

  @override
  Future<void> sep6SimulateBankTransfer(String anchorId, String anchorToken, String txId,
      {required String amount}) async {
    status = 'completed';
    amountOut = '2.0000000';
  }

  @override
  Future<void> reportTransaction(String anchorId, String txId,
      {required String kind, required String state, String? amount, int? decimals, String? stellarTxHash}) async {
    reports.add({'kind': kind, 'state': state, 'amount': amount, 'decimals': decimals, 'hash': stellarTxHash});
  }

  @override
  Future<List<AnchorTransaction>> transactions(String anchorId) async {
    ledgerFetches++;
    return ledger;
  }
}

class _FakeWithdrawApi extends _FakeAnchorApi {
  _FakeWithdrawApi(this.unsignedXdr);
  final String unsignedXdr;
  final paymentRequests = <Map<String, String>>[];

  @override
  Future<Sep6Withdraw> sep6Withdraw(String anchorId, String anchorToken,
          {required String assetCode, required String amount}) async =>
      Sep6Withdraw.fromJson({
        'id': 'sep_w1',
        'account_id': _treasury,
        'memo_type': 'id',
        'memo': '586146517297',
        'extra_info': {'message': 'Send 5 USDC to the treasury'},
      });

  @override
  Future<String> withdrawPaymentXdr(String anchorId,
      {required String destination, required String memoType, required String memo, required String amount}) async {
    paymentRequests.add({'destination': destination, 'memoType': memoType, 'memo': memo, 'amount': amount});
    return unsignedXdr;
  }
}

class _FakeTxApi extends Fake implements TxApi {
  final submitted = <Map<String, String>>[];

  @override
  Future<SubmitResponse> submit({
    required String idempotencyKey,
    required String purpose,
    required TxKind kind,
    required String xdr,
  }) async {
    submitted.add({'purpose': purpose, 'xdr': xdr});
    return const SubmitResponse(hash: 'abc123', successful: true, replayed: false);
  }
}

class _UnlockedWallet extends WalletNotifier {
  _UnlockedWallet(this.keyPair);
  final KeyPair keyPair;

  @override
  WalletState build() => WalletState(keyPair: keyPair);
}

final _treasury = KeyPair.random().accountId;

class _PresetSession extends AnchorSessionNotifier {
  @override
  String? build() => 'anchor-jwt';
}

class _FakeSync extends SyncNotifier {
  @override
  Future<SyncResponse> build() async => const SyncResponse(
        cheques: [],
        pool: PoolDeposit(ownerAddress: 'G', amountRaw: '0', decimals: 7, updatedAt: ''),
        trustlineReady: true,
        ledgerSeq: 1,
        serverTimeUnix: 0,
      );

  int refreshes = 0;

  // The real refresh() would hit the network via Dio.
  @override
  Future<void> refresh() async => refreshes++;
}

class _CountingSession extends AnchorSessionNotifier {
  _CountingSession(this.onLogin);
  final void Function() onLogin;
  var _n = 0;

  @override
  String? build() => 'stale';

  @override
  Future<void> login(String anchorId) async {
    onLogin();
    state = 'fresh-${++_n}';
  }
}

Widget _app(_FakeAnchorApi api, {List<Override> extra = const []}) => ProviderScope(
      overrides: [
        ...extra,
        anchorApiProvider.overrideWithValue(api),
        primaryAnchorProvider.overrideWithValue(_anchor),
        anchorSessionProvider.overrideWith(_PresetSession.new),
        syncProvider.overrideWith(_FakeSync.new),
        // Trustline readiness for the anchor's OWN asset (USDC here) comes
        // from the account's own balances, independent of `/sync`'s
        // platform-asset `trustlineReady` — an already-open USDC trustline.
        balancesProvider.overrideWith(
          (ref) async => const AccountBalances(native: '100', other: {'USDC': '10'}),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        home: const Scaffold(body: Padding(padding: EdgeInsets.all(20), child: AnchorDepositWithdrawPage())),
      ),
    );

Future<void> _enterAmountAndTap(WidgetTester tester, String amount, String button) async {
  await tester.enterText(find.byType(TextField), amount);
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, button));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('deposit: shows the anchor bank instructions, then completes and reports the ledger', (tester) async {
    final api = _FakeAnchorApi();
    await tester.pumpWidget(_app(api));
    await tester.pump();

    await _enterAmountAndTap(tester, '100', 'Deposit');

    // The anchor was asked for a TRY amount, with the anchor JWT.
    expect(api.depositCalls.single, {'token': 'anchor-jwt', 'asset': 'USDC', 'amount': '100'});
    expect(find.text('Deposit 100 TRY'), findsOneWidget);
    expect(find.text('Waiting for your bank transfer'), findsOneWidget);
    expect(find.text('TR050009900000000000000001'), findsOneWidget);
    expect(find.text('TRMA-A9LA-MULF'), findsOneWidget);
    expect(find.text('Bank account number'), findsOneWidget);

    await tester.tap(find.text('Simulate bank transfer (sandbox)'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('You received 2.0000000 USDC.'), findsOneWidget);
    // Reported once, in RAW units (7 decimals), not the display string.
    expect(api.reports, [
      {'kind': 'deposit', 'state': 'completed', 'amount': '20000000', 'decimals': 7, 'hash': null},
    ]);

    // "Done" returns to the empty form.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Done'));
    await tester.pump();
    expect(find.text('Amount to deposit'), findsOneWidget);

    // Leaving the screen must cancel polling (no timer left behind).
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('polling picks up progress and stops at a terminal state', (tester) async {
    final api = _FakeAnchorApi();
    await tester.pumpWidget(_app(api));
    await tester.pump();
    await _enterAmountAndTap(tester, '100', 'Deposit');

    api.status = 'pending_anchor';
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('The anchor is processing it'), findsOneWidget);

    api
      ..status = 'completed'
      ..amountOut = '2.0000000';
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Completed'), findsOneWidget);
    expect(api.reports, hasLength(1));

    // No further ticks after completion.
    await tester.pump(const Duration(seconds: 9));
    expect(api.reports, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("an anchor refusal is shown in the anchor's own words", (tester) async {
    final api = _FakeAnchorApi()
      ..depositError = ApiException(
        code: 'anchor.upstream_failed',
        message: 'anchor.upstream_failed: anchor returned 400: {"error":"amount below the 50 TRY minimum"}',
      );
    await tester.pumpWidget(_app(api));
    await tester.pump();
    await _enterAmountAndTap(tester, '10', 'Deposit');

    expect(find.text('amount below the 50 TRY minimum'), findsOneWidget);
    // Still on the form so the user can correct the amount.
    expect(find.text('Amount to deposit'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('deposit amounts with more than 2 decimals or junk keep the button disabled', (tester) async {
    await tester.pumpWidget(_app(_FakeAnchorApi()));
    await tester.pump();

    bool enabled() => tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Deposit')).onPressed != null;
    for (final bad in ['', '0', '1.234', 'abc', '-5']) {
      await tester.enterText(find.byType(TextField), bad);
      await tester.pump();
      expect(enabled(), isFalse, reason: '"$bad"');
    }
    await tester.enterText(find.byType(TextField), '50.25');
    await tester.pump();
    expect(enabled(), isTrue);
  });

  testWidgets('withdraw: pays the anchor with a signed payment, then reports completion with the tx hash',
      (tester) async {
    final keyPair = KeyPair.random();
    final unsigned = TransactionBuilder(Account(keyPair.accountId, BigInt.from(5)))
        .addOperation(PaymentOperationBuilder(
                _treasury, Asset.createNonNativeAsset('USDC', _anchor.assetIssuer), '5.0000000')
            .build())
        .build()
        .toEnvelopeXdrBase64();
    final api = _FakeWithdrawApi(unsigned);
    final txApi = _FakeTxApi();
    await tester.pumpWidget(_app(api, extra: [
      txApiProvider.overrideWithValue(txApi),
      walletProvider.overrideWith(() => _UnlockedWallet(keyPair)),
    ]));
    await tester.pump();

    await tester.tap(find.text('Withdraw'));
    await tester.pump();
    expect(find.text('Amount to withdraw'), findsOneWidget);
    await _enterAmountAndTap(tester, '5', 'Withdraw');
    await tester.pump();

    // The backend was asked to build the payment to the anchor's account with its memo.
    expect(api.paymentRequests.single, {
      'destination': _treasury,
      'memoType': 'id',
      'memo': '586146517297',
      'amount': '5',
    });
    // The device signed it (a signature was added) and submitted it.
    final submitted = txApi.submitted.single;
    expect(submitted['purpose'], 'anchor_withdraw');
    expect(submitted['xdr'], isNot(unsigned));
    final signedTx = AbstractTransaction.fromEnvelopeXdrString(submitted['xdr']!);
    expect(signedTx.signatures, hasLength(1));

    expect(find.text('Withdraw 5 USDC'), findsOneWidget);
    expect(find.text('Send 5 USDC to the treasury'), findsOneWidget);

    api.status = 'completed';
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('TRY is on its way to your bank.'), findsOneWidget);
    // RAW units for 5 USDC, and the hash of OUR payment.
    expect(api.reports, [
      {'kind': 'withdraw', 'state': 'completed', 'amount': '50000000', 'decimals': 7, 'hash': 'abc123'},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('starting a transfer makes the ledger (and so Recent activity) look again', (tester) async {
    final api = _FakeAnchorApi();
    await tester.pumpWidget(_app(api));
    await tester.pump();
    final before = api.ledgerFetches;

    await _enterAmountAndTap(tester, '100', 'Deposit');
    await tester.pump();

    expect(api.depositCalls, hasLength(1));
    expect(api.ledgerFetches, greaterThan(before), reason: 'the backend opened a row for it');
  });

  group('reconciling transfers left in flight', () {
    AnchorTransaction row({String id = 'sep_old', String kind = 'deposit', String state = 'pending_user_transfer_start'}) =>
        AnchorTransaction(
          id: id,
          anchorId: 'default',
          kind: kind,
          state: state,
          startedAt: '2026-09-20T08:00:00Z',
          updatedAt: '2026-09-20T08:00:00Z',
        );

    Future<void> open(WidgetTester tester, _FakeAnchorApi api) async {
      await tester.pumpWidget(_app(api));
      // ledger load -> anchor status -> report
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
    }

    testWidgets('a deposit the anchor has since completed is reported to the ledger', (tester) async {
      final api = _FakeAnchorApi()
        ..ledger = [row()]
        ..status = 'completed'
        ..amountOut = '2.0000000';
      await open(tester, api);

      expect(api.statusChecks, ['sep_old']);
      expect(api.reports.single['kind'], 'deposit');
      expect(api.reports.single['state'], 'completed');
      expect(api.reports.single['amount'], '20000000');
      expect(api.reports.single['decimals'], 7);
    });

    testWidgets('a row whose status has not moved is not reported again', (tester) async {
      final api = _FakeAnchorApi()..ledger = [row()]; // anchor still says pending_user_transfer_start
      await open(tester, api);

      expect(api.statusChecks, ['sep_old']);
      expect(api.reports, isEmpty);
    });

    testWidgets('rows already in a final state are not asked about', (tester) async {
      final api = _FakeAnchorApi()
        ..ledger = [row(id: 'a', state: 'completed'), row(id: 'b', state: 'expired'), row(id: 'c', state: 'error')];
      await open(tester, api);

      expect(api.statusChecks, isEmpty);
      expect(api.reports, isEmpty);
    });

    testWidgets('an anchor that cannot be reached is ignored — the screen still works', (tester) async {
      final api = _FakeAnchorApi()
        ..ledger = [row()]
        ..statusError = StateError('anchor down');
      await open(tester, api);

      expect(api.statusChecks, ['sep_old']);
      expect(api.reports, isEmpty);
      expect(tester.takeException(), isNull);
      // Still usable: the start button is there and the recent list shows the row.
      expect(find.widgetWithText(ElevatedButton, 'Deposit'), findsOneWidget);
      expect(find.text('Recent bank activity'), findsOneWidget);
    });

    testWidgets('only the newest few are checked, so a long backlog does not flood the anchor', (tester) async {
      final api = _FakeAnchorApi()..ledger = [for (var i = 0; i < 8; i++) row(id: 'sep_$i')];
      await open(tester, api);

      expect(api.statusChecks, ['sep_0', 'sep_1', 'sep_2', 'sep_3', 'sep_4']);
    });
  });

  test('AnchorInfo parses a backend response that omits transferServer24', () {
    // The TR anchor publishes no SEP-24 server, so the backend omits the key.
    final info = AnchorInfo.fromJson({
      'id': 'default',
      'domain': 'tr-mock-anchor.fly.dev',
      'signingKey': 'GSIGNING',
      'webAuthEndpoint': 'https://tr-mock-anchor.fly.dev/auth',
      'transferServer': 'https://tr-mock-anchor.fly.dev/sep6',
      'assetCode': 'USDC',
      'assetIssuer': 'GISSUER',
    });
    expect(info.transferServer24, '');
  });

  test('withToken re-logs-in once when the anchor rejects the token, and not for other errors', () async {
    var logins = 0;
    final container = ProviderContainer(overrides: [
      anchorSessionProvider.overrideWith(() => _CountingSession(() => logins++)),
    ]);
    addTearDown(container.dispose);
    final session = container.read(anchorSessionProvider.notifier);

    // 1) expired token -> one re-login, then the call succeeds.
    final tokens = <String>[];
    final result = await session.withToken<String>('default', (t) async {
      tokens.add(t);
      if (tokens.length == 1) throw ApiException(code: 'anchor.token_rejected', message: 'x');
      return 'ok';
    });
    expect(result, 'ok');
    expect(tokens, ['stale', 'fresh-1']);
    expect(logins, 1);

    // 2) rejected again -> surfaces instead of looping.
    var attempts = 0;
    await expectLater(
      session.withToken<void>('default', (t) async {
        attempts++;
        throw ApiException(code: 'anchor.token_rejected', message: 'x');
      }),
      throwsA(isA<ApiException>()),
    );
    expect(attempts, 2);

    // 3) any other error is not retried.
    var other = 0;
    await expectLater(
      session.withToken<void>('default', (t) async {
        other++;
        throw ApiException(code: 'anchor.bad_request', message: 'x');
      }),
      throwsA(isA<ApiException>()),
    );
    expect(other, 1);
  });
}
