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

const _usdcIssuer = 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';

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

  /// The (single) transaction that was submitted, as the network would read it.
  Transaction get submittedTx {
    final unsigned = tx.submitted.single.xdr.replaceFirst('signed-', '');
    return AbstractTransaction.fromEnvelopeXdrString(unsigned) as Transaction;
  }
}

/// A funded account that holds USDC (a zero balance still means "trustline").
AccountBalances _withUsdc(String amount) => FakeHorizonReadService.fundedBalances(other: {'USDC': amount});

void main() {
  test('a brand-new wallet: fees from the faucet, then ONE transaction opens USDC and buys it', () async {
    final h = _Harness(balances: [
      AccountBalances.notFunded, // Horizon doesn't serve the fresh account yet
      FakeHorizonReadService.fundedBalances(),
      _withUsdc('105.1817771'),
    ]);
    final labels = <String>[];

    final result = await h.funds.run(progress: labels.add);

    expect(h.auth.fundCalls, 1);
    expect(labels, ['Preparing your wallet…', 'Getting USDC…']);
    expect(h.tx.submitted, hasLength(1), reason: 'trustline and trade travel together');
    expect(h.tx.submitted.single.purpose, 'starter_swap');
    expect(h.tx.submitted.single.kind, TxKind.classic);

    final ops = h.submittedTx.operations;
    expect(ops, hasLength(2));
    final trust = (ops[0] as ChangeTrustOperation).asset as AssetTypeCreditAlphaNum;
    expect(trust.code, 'USDC');
    expect(trust.issuerId, _usdcIssuer);

    // What the wallet gained is read back, not assumed.
    expect(result.usdcAdded, '105.1817771');
  });

  test('the trade sells native coin for USDC to the wallet itself, with a floor under the price', () async {
    final h = _Harness(balances: [_withUsdc('0.0000000')]);

    await h.funds.run();

    final pay = h.submittedTx.operations.single as PathPaymentStrictSendOperation;
    expect(pay.sendAsset, isA<AssetTypeNative>());
    expect(pay.sendAmount, starterSwapSend);
    expect(pay.destination.accountId, h.wallet.accountId);
    expect((pay.destAsset as AssetTypeCreditAlphaNum).code, 'USDC');
    // 95 % of the quoted 105.1817771, in whole stroops.
    expect(pay.destMin, '99.9226882');
    expect(h.horizon.quoted, [starterSwapSend]);
  });

  test('the transaction is built on the account\'s current sequence and expires soon', () async {
    final h = _Harness(balances: [_withUsdc('0.0000000')]);
    h.horizon.sequence = BigInt.from(4242);

    await h.funds.run();

    final tx = h.submittedTx;
    expect(tx.sequenceNumber, BigInt.from(4243));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(tx.preconditions!.timeBounds!.maxTime, greaterThan(now));
    expect(tx.preconditions!.timeBounds!.maxTime, lessThan(now + 600));
  });

  test('a wallet that already has the USDC trustline only trades — nothing to open or confirm', () async {
    final h = _Harness(balances: [_withUsdc('0.0000000'), _withUsdc('105.1817771')]);

    final result = await h.funds.run();

    expect(h.submittedTx.operations.single, isA<PathPaymentStrictSendOperation>());
    expect(h.anchor.calls, isEmpty);
    expect(result.usdcAdded, '105.1817771');
  });

  test('only what was gained is reported when the wallet already held some', () async {
    final h = _Harness(balances: [_withUsdc('10.0000000'), _withUsdc('115.1817771')]);

    final result = await h.funds.run();

    expect(result.usdcAdded, '105.1817771');
  });

  test('the backend is told about a trustline the trade opened', () async {
    final h = _Harness();

    await h.funds.run();

    expect(h.anchor.calls, ['trustlineConfirm']);
    expect(h.container.read(syncProvider).value?.trustlineReady, isTrue);
  });

  test('a failed trustline bookkeeping call does not turn a successful top-up into a failure', () async {
    final h = _Harness();
    h.anchor.confirmError = apiError('anchor.trustline_missing');

    final result = await h.funds.run();

    expect(h.tx.submitted, hasLength(1));
    expect(result, isA<StarterFundsResult>());
  });

  group('the faucet step', () {
    test('an account with enough for fees is not sent to the faucet again', () async {
      final h = _Harness(balances: [_withUsdc('1.0000000')]);
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
      expect(h.tx.submitted, hasLength(1));
    });

    test('the faucet says no and the account still does not exist → auth.fund_failed, nothing is traded',
        () async {
      final h = _Harness(balances: [AccountBalances.notFunded]);
      h.auth.fundResult = false;

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'auth.fund_failed')),
      );
      expect(h.tx.submitted, isEmpty);
      expect(h.horizon.quoted, isEmpty);
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

  group('failures name what went wrong', () {
    test('no liquidity → starter.no_liquidity, nothing is submitted', () async {
      final h = _Harness();
      h.horizon.quote = null;

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'starter.no_liquidity')),
      );
      expect(h.tx.submitted, isEmpty);
    });

    test('the network rejecting the trade (price moved past the floor) is surfaced and nothing is confirmed',
        () async {
      final h = _Harness();
      h.tx.submitError = apiError('tx.submit_failed', 'op_under_dest_min');

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'tx.submit_failed')),
      );
      expect(h.anchor.calls, isEmpty);
    });

    test('an account Horizon has no sequence for is reported, not built on a guess', () async {
      final h = _Harness();
      h.horizon.sequence = null;

      await expectLater(
        h.funds.run(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'auth.fund_failed')),
      );
      expect(h.tx.submitted, isEmpty);
    });
  });

  test('a retry after a failed trade just tries again: each attempt is its own idempotency key', () async {
    final h = _Harness(balances: [
      FakeHorizonReadService.fundedBalances(),
      FakeHorizonReadService.fundedBalances(),
      _withUsdc('105.1817771'),
    ]);
    h.tx.submitError = apiError('tx.submit_failed');
    await expectLater(h.funds.run(), throwsA(isA<ApiException>()));

    h.tx.submitError = null;
    final result = await h.funds.run();

    expect(result.usdcAdded, isNotNull);
    expect(h.tx.submitted, hasLength(2));
    expect(h.tx.submitted[0].idempotencyKey, isNot(h.tx.submitted[1].idempotencyKey));
  });
}
