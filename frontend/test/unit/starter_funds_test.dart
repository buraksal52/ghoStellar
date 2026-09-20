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
    int maxPollFailures = 3,
  })  : anchor = FakeStarterAnchorApi(),
        auth = FakeAuthApi(),
        tx = FakeTxApi() {
    horizon = TrustlineAwareHorizon(
      anchor,
      balances ??
          [
            FakeHorizonReadService.fundedBalances(
              other: trustlineAlreadyReady ? {'USDC': '0.0000000'} : const {},
            ),
          ],
    );
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
          maxPollFailures: maxPollFailures,
        ),
      ),
    ]);
  }

  final FakeStarterAnchorApi anchor;
  final FakeAuthApi auth;
  final FakeTxApi tx;
  late final TrustlineAwareHorizon horizon;
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

    test('an account that already exists is fine even if friendbot would refuse it again', () async {
      final h = _Harness();
      h.auth.fundResult = false; // friendbot: "already funded"

      final result = await h.funds.run();

      expect(result.usdcAdded, isNotNull);
      expect(h.auth.fundCalls, 0, reason: 'nothing to fund, so friendbot is not even asked');
    });

    test('an account that is short on network fees is topped up', () async {
      final h = _Harness(balances: [FakeHorizonReadService.fundedBalances(native: '1.5000000')]);

      await h.funds.run();

      expect(h.auth.fundCalls, 1);
    });

    test('a Horizon that cannot be read yet does not stop the flow: friendbot is asked and Horizon retried', () async {
      final h = _Harness(balances: [AccountBalances.notFunded, FakeHorizonReadService.fundedBalances()]);
      h.horizon.failFirstReads = 1;

      final result = await h.funds.run();

      expect(h.auth.fundCalls, 1);
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

  test('the trustline is read off Horizon: an account that has it is not asked to set it up again', () async {
    final h = _Harness(trustlineAlreadyReady: true);

    await h.funds.run();

    expect(h.anchor.calls, isNot(contains('trustlineXdr')));
    final sync = h.container.read(syncProvider.notifier) as TrustlineAwareSync;
    expect(sync.refreshes, 1, reason: 'only the bookkeeping refresh after the deposit — no /sync before it');
  });

  test('the anchor login starts alongside the wallet setup, not after it', () async {
    final h = _Harness();
    h.container.read(anchorSessionProvider.notifier).clear();

    await h.funds.run();

    expect(h.container.read(anchorSessionProvider), 'fresh-jwt');
    expect(h.anchor.calls.indexOf('challenge'), lessThan(h.anchor.calls.indexOf('trustlineXdr')));
    expect(h.anchor.calls.where((c) => c == 'token'), hasLength(1), reason: 'one login, reused for every call');
  });

  group('waiting for the bank', () {
    test('says what the anchor is doing, once per change, never for the final state', () async {
      final h = _Harness(trustlineAlreadyReady: true);
      h.anchor.statuses = ['pending_anchor', 'pending_anchor', 'pending_stellar', 'completed'];
      final labels = <String>[];

      await h.funds.run(progress: labels.add);

      expect(labels.skip(labels.indexOf('Waiting for the bank…') + 1), [
        'The anchor is processing it',
        'Sending on Stellar',
      ]);
    });

    test('announces the wait the user may walk away from, right when it starts', () async {
      final h = _Harness(trustlineAlreadyReady: true);
      final events = <String>[];

      await h.funds.run(progress: events.add, canContinueInBackground: () => events.add('background'));

      expect(events.last, 'background');
      expect(events[events.length - 2], 'Waiting for the bank…');
    });

    test('a deposit the anchor holds for a trustline opens it once, then carries on', () async {
      final h = _Harness(trustlineAlreadyReady: true);
      h.anchor.statuses = ['pending_trust', 'pending_anchor', 'completed'];
      final labels = <String>[];

      final result = await h.funds.run(progress: labels.add);

      expect(h.anchor.calls.where((c) => c == 'trustlineXdr'), hasLength(1));
      expect(labels, contains('Enabling USDC…'));
      expect(result.usdcAdded, '24.1000000');
    });

    test('a blip or two in the polling is ridden out', () async {
      final h = _Harness(trustlineAlreadyReady: true);
      h.anchor.pollFailures = 2;

      final result = await h.funds.run();

      expect(result.usdcAdded, '24.1000000');
    });

    test('an anchor that cannot be reached is reported at once, not after the whole wait', () async {
      final h = _Harness(trustlineAlreadyReady: true, maxPolls: 50);
      h.anchor.pollFailures = 99;

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'network.error')),
      );
      expect(h.anchor.polls, 0, reason: 'every poll failed');
      expect(h.anchor.calls.where((c) => c == 'transaction'), hasLength(3));
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
