import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/state/anchor_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/starter_funds.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' hide AnchorTransaction;

import '../support/fakes.dart';

/// Everything the flow talks to, faked, plus the container to run it in.
class _Harness {
  _Harness({
    List<AccountBalances>? balances,
    bool trustlineAlreadyReady = false,
    int maxPolls = 5,
  })  : anchor = FakeStarterAnchorApi(),
        auth = FakeAuthApi(),
        tx = FakeTxApi(),
        horizon = FakeHorizonReadService(balances ?? [FakeHorizonReadService.fundedBalances()]) {
    container = ProviderContainer(overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      authApiProvider.overrideWithValue(auth),
      anchorApiProvider.overrideWithValue(anchor),
      txApiProvider.overrideWithValue(tx),
      stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
      horizonReadServiceProvider.overrideWithValue(horizon),
      syncProvider.overrideWith(() => TrustlineAwareSync(anchor, alreadyReady: trustlineAlreadyReady)),
      primaryAnchorProvider.overrideWithValue(testAnchor),
      anchorSessionProvider.overrideWith(PresetAnchorSession.new),
      starterFundsProvider.overrideWith(
        (ref) => StarterFunds(
          ref,
          pollInterval: Duration.zero,
          accountRetryDelay: Duration.zero,
          maxPolls: maxPolls,
        ),
      ),
    ]);
  }

  final FakeStarterAnchorApi anchor;
  final FakeAuthApi auth;
  final FakeTxApi tx;
  final FakeHorizonReadService horizon;
  late final ProviderContainer container;

  StarterFunds get funds => container.read(starterFundsProvider);
}

void main() {
  test('a brand-new wallet gets fees, a USDC trustline and USDC — in that order', () async {
    final h = _Harness(
      // Horizon doesn't serve the freshly funded account on the first read.
      balances: [AccountBalances.notFunded, FakeHorizonReadService.fundedBalances()],
    );
    final labels = <String>[];

    final result = await h.funds.run(progress: labels.add);

    expect(h.auth.fundCalls, 1);
    expect(h.horizon.fetchCalls, 2, reason: 'read again until the account shows');
    expect(h.anchor.calls, [
      'trustlineXdr',
      'trustlineConfirm',
      'deposit',
      'simulate',
      'transaction',
      'report',
    ]);
    expect(h.tx.submitted.single.purpose, 'trustline');
    expect(h.tx.submitted.single.kind, TxKind.classic);
    expect(h.anchor.depositedAmount, starterDepositTry);
    expect(result.usdcAdded, '24.1000000');
    expect(labels, [
      'Preparing your wallet…',
      'Enabling USDC…',
      'Requesting a deposit…',
      'Waiting for the bank…',
    ]);
  });

  test('the anchor ledger is told about the deposit, with the on-chain amount', () async {
    final h = _Harness();
    await h.funds.run();

    expect(h.anchor.report, {
      'kind': 'deposit',
      'state': 'completed',
      'amount': '241000000', // 24.1 USDC, 7 decimals
      'decimals': 7,
      'hash': 'stellar-hash',
    });
  });

  test('an already-open trustline is not opened again', () async {
    final h = _Harness(trustlineAlreadyReady: true);
    final labels = <String>[];

    await h.funds.run(progress: labels.add);

    expect(h.anchor.calls, isNot(contains('trustlineXdr')));
    expect(h.tx.submitted, isEmpty);
    expect(labels, isNot(contains('Enabling USDC…')));
    expect(h.anchor.calls, contains('deposit'));
  });

  test('polls until the anchor reaches a final state', () async {
    final h = _Harness(trustlineAlreadyReady: true);
    h.anchor.statuses = ['pending_anchor', 'pending_stellar', 'completed'];

    final result = await h.funds.run();

    expect(h.anchor.polls, 3);
    expect(result.usdcAdded, '24.1000000');
  });

  group('failures name the step that failed', () {
    test('friendbot says no and the account still does not exist → auth.fund_failed, nothing else runs', () async {
      final h = _Harness(balances: [AccountBalances.notFunded]);
      h.auth.fundResult = false;

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'auth.fund_failed')),
      );
      expect(h.anchor.calls, isEmpty);
    });

    test('the fund call itself failing is reported when the account is still missing', () async {
      final h = _Harness(balances: [AccountBalances.notFunded]);
      h.auth.fundError = apiError('network.error');

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'network.error')),
      );
    });

    test('an account that already exists is fine even if friendbot refuses it again', () async {
      final h = _Harness();
      h.auth.fundResult = false; // friendbot: "already funded"

      final result = await h.funds.run();

      expect(result.usdcAdded, isNotNull);
    });

    test('a bank deposit that never finishes is reported as pending, not as a failure to fund', () async {
      final h = _Harness(trustlineAlreadyReady: true, maxPolls: 3);
      h.anchor.statuses = ['pending_anchor'];

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'anchor.deposit_pending')),
      );
      expect(h.anchor.polls, 3);
      expect(h.anchor.report, isNull, reason: 'nothing final to record yet');
    });

    test('a deposit the anchor gives up on is recorded and reported as failed', () async {
      final h = _Harness(trustlineAlreadyReady: true);
      h.anchor.statuses = ['error'];

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'anchor.deposit_failed')),
      );
      expect(h.anchor.report?['state'], 'error');
    });

    test('the anchor refusing the deposit surfaces its own error', () async {
      final h = _Harness(trustlineAlreadyReady: true);
      h.anchor.depositError = apiError('anchor.upstream_failed', '{"error":"amount too large"}');

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'anchor.upstream_failed')),
      );
    });
  });

  test('a retry after a failed deposit carries on: fees and trustline are not redone', () async {
    final h = _Harness();
    h.anchor.depositError = apiError('anchor.upstream_failed');
    await expectLater(h.funds.run(), throwsA(isA<ApiException>()));
    expect(h.anchor.calls.where((c) => c == 'trustlineXdr'), hasLength(1));

    h.anchor.depositError = null;
    final result = await h.funds.run();

    expect(result.usdcAdded, '24.1000000');
    expect(h.anchor.calls.where((c) => c == 'trustlineXdr'), hasLength(1),
        reason: 'the trustline opened the first time');
    expect(h.tx.submitted, hasLength(1));
  });
}
