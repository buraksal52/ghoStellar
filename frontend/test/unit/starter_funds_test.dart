import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
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
  _Harness({List<AccountBalances>? balances})
      : anchor = FakeStarterAnchorApi(),
        auth = FakeAuthApi(),
        tx = FakeTxApi(),
        horizon = FakeHorizonReadService(balances ?? [FakeHorizonReadService.fundedBalances()]),
        wallet = KeyPair.random() {
    container = ProviderContainer(overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(wallet)),
      authApiProvider.overrideWithValue(auth),
      anchorApiProvider.overrideWithValue(anchor),
      txApiProvider.overrideWithValue(tx),
      stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
      horizonReadServiceProvider.overrideWithValue(horizon),
      syncProvider.overrideWith(() => TrustlineAwareSync(anchor)),
      primaryAnchorProvider.overrideWithValue(testAnchor),
      starterFundsProvider.overrideWith((ref) => StarterFunds(ref, accountRetryDelay: Duration.zero)),
    ]);
  }

  final FakeStarterAnchorApi anchor;
  final FakeAuthApi auth;
  final FakeTxApi tx;
  final FakeHorizonReadService horizon;
  final KeyPair wallet;
  late final ProviderContainer container;

  StarterFunds get funds => container.read(starterFundsProvider);
}

void main() {
  // The app's one asset is native XLM by default, so "getting test funds" is
  // just friendbot topping up the account — no trustline, no DEX trade, no
  // transaction signed or submitted at all.
  test('a brand-new wallet: the faucet funds it, nothing is signed or submitted', () async {
    final h = _Harness(balances: [
      AccountBalances.notFunded, // Horizon doesn't serve the fresh account yet
      FakeHorizonReadService.fundedBalances(),
    ]);
    final labels = <String>[];

    final result = await h.funds.run(progress: labels.add);

    expect(h.auth.fundCalls, 1);
    expect(labels, ['Preparing your wallet…']);
    expect(h.tx.submitted, isEmpty);
    expect(h.anchor.calls, isEmpty);
    expect(result.added, '10000.0000000');
  });

  test('an already-funded wallet is left alone: no faucet call, nothing gained', () async {
    final h = _Harness(balances: [FakeHorizonReadService.fundedBalances()]);

    final result = await h.funds.run();

    expect(h.auth.fundCalls, 0);
    expect(result.added, isNull);
  });

  test('only what was gained is reported when the wallet already held some', () async {
    final h = _Harness(balances: [
      AccountBalances.notFunded,
      FakeHorizonReadService.fundedBalances(native: '10.0000000'),
    ]);

    final result = await h.funds.run();

    expect(result.added, '10.0000000');
  });

  group('the faucet step', () {
    test('an account with enough for fees is not sent to the faucet again', () async {
      final h = _Harness(balances: [FakeHorizonReadService.fundedBalances()]);
      h.auth.fundResult = false; // friendbot would refuse it

      await h.funds.run();

      expect(h.auth.fundCalls, 0);
    });

    test('an account that is short on fees is topped up', () async {
      final h = _Harness(balances: [FakeHorizonReadService.fundedBalances(native: '1.5000000')]);

      await h.funds.run();

      expect(h.auth.fundCalls, 1);
    });

    test('a Horizon that cannot be read yet does not stop the flow: the faucet is asked, Horizon retried',
        () async {
      final h = _Harness(balances: [AccountBalances.notFunded, FakeHorizonReadService.fundedBalances()]);
      h.horizon.failFirstReads = 1;

      await h.funds.run();

      expect(h.auth.fundCalls, 1);
    });

    test('the faucet says no and the account still does not exist → auth.fund_failed', () async {
      final h = _Harness(balances: [AccountBalances.notFunded]);
      h.auth.fundResult = false;

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'auth.fund_failed')),
      );
    });

    test('the fund call itself failing is reported when the account is still missing', () async {
      final h = _Harness(balances: [AccountBalances.notFunded]);
      h.auth.fundError = apiError('network.error');

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'network.error')),
      );
    });
  });
}
