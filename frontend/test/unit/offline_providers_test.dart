import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/config/pay_asset.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';
import 'package:ghostellar_app/data/storage/offline_payment_store.dart';
import 'package:ghostellar_app/data/stellar/offline_account_cache.dart';
import 'package:ghostellar_app/data/stellar/offline_payment_builder.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/offline_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _networkPassphrase = 'Test SDF Network ; September 2015';

String _validXdr({KeyPair? sender, KeyPair? receiver, BigInt? sequence, String nonce = 'n'}) {
  const builder = OfflinePaymentBuilder();
  final s = sender ?? KeyPair.random();
  final r = receiver ?? KeyPair.random();
  return builder.buildAndSign(
    sender: s,
    snapshot: OfflineAccountSnapshot(
      accountId: s.accountId,
      sequence: sequence ?? BigInt.from(10),
      availableRaw: '100000000',
      decimals: 7,
      fetchedAt: DateTime.utc(2026, 9, 20),
    ),
    destination: r.accountId,
    amount: '5',
    nonce: nonce,
    asset: const PayAsset(code: 'USDC', issuer: 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5'),
    networkPassphrase: _networkPassphrase,
  );
}

/// A pending offline payment ready for the notifier — a genuine signed XDR
/// each time (retryAll always has to hash it to build the idempotency key).
PendingOfflinePayment _payment(String nonce, {String from = 'GFROM', String? signedXdr}) =>
    PendingOfflinePayment(
      signedXdr: signedXdr ?? _validXdr(nonce: nonce),
      nonce: nonce,
      from: from,
      amountRaw: '50000000',
      decimals: 7,
      receivedAt: DateTime.utc(2026, 9, 20),
    );

class _Rig {
  final chequeApi = FakeChequeApi();
  final txApi = FakeTxApi();
  ProviderContainer? _container;

  ProviderContainer build({bool unlocked = true, KeyPair? keyPair}) {
    final c = ProviderContainer(overrides: <Override>[
      chequeApiProvider.overrideWithValue(chequeApi),
      txApiProvider.overrideWithValue(txApi),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [])),
      if (unlocked) walletProvider.overrideWith(() => UnlockedWallet(keyPair ?? KeyPair.random())),
    ]);
    _container = c;
    return c;
  }

  void dispose() => _container?.dispose();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('OfflineAccountSnapshot', () {
    test('reserve deducts the amount and advances the sequence', () {
      final s = OfflineAccountSnapshot(
        accountId: 'G',
        sequence: BigInt.from(5),
        availableRaw: '100000000',
        decimals: 7,
        fetchedAt: DateTime.utc(2026, 9, 20),
      );
      final next = s.reserve('30000000');
      expect(next.sequence, BigInt.from(6));
      expect(next.availableRaw, '70000000');
    });

    test('reserve never goes negative', () {
      final s = OfflineAccountSnapshot(
        accountId: 'G',
        sequence: BigInt.from(5),
        availableRaw: '10',
        decimals: 7,
        fetchedAt: DateTime.utc(2026, 9, 20),
      );
      expect(s.reserve('999').availableRaw, '0');
    });

    test('round-trips through JSON, sequence included exactly', () {
      final s = OfflineAccountSnapshot(
        accountId: 'GABC',
        sequence: BigInt.parse('9223372036854775807'),
        availableRaw: '12345',
        decimals: 7,
        fetchedAt: DateTime.utc(2026, 9, 20, 1, 2, 3),
      );
      final back = OfflineAccountSnapshot.fromJson(s.toJson());
      expect(back.accountId, s.accountId);
      expect(back.sequence, s.sequence);
      expect(back.availableRaw, s.availableRaw);
      expect(back.fetchedAt, s.fetchedAt);
    });
  });

  group('AccountSnapshotNotifier', () {
    test('starts from whatever is cached on disk', () async {
      await OfflineAccountCache().write(OfflineAccountSnapshot(
        accountId: 'G',
        sequence: BigInt.one,
        availableRaw: '1',
        decimals: 7,
        fetchedAt: DateTime.utc(2026, 9, 20),
      ));
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(await container.read(accountSnapshotProvider.notifier).future, isNotNull);
    });

    test('reserve persists the reduced snapshot', () async {
      final cache = OfflineAccountCache();
      await cache.write(OfflineAccountSnapshot(
        accountId: 'G',
        sequence: BigInt.from(5),
        availableRaw: '100',
        decimals: 7,
        fetchedAt: DateTime.utc(2026, 9, 20),
      ));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(accountSnapshotProvider.notifier);
      await notifier.future;

      await notifier.reserve('40');

      expect((await notifier.future)!.availableRaw, '60');
      expect((await cache.read())!.availableRaw, '60');
    });

    test('reserve with no cached snapshot does nothing', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(accountSnapshotProvider.notifier);
      await notifier.future;

      await notifier.reserve('40'); // must not throw

      expect(await notifier.future, isNull);
    });
  });

  group('OfflineSpentRequestIdsNotifier', () {
    test('starts empty, hydrates, and accepts new ids', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(offlineSpentRequestIdsProvider), isEmpty);

      container.read(offlineSpentRequestIdsProvider.notifier).hydrate({'a', 'b'});
      container.read(offlineSpentRequestIdsProvider.notifier).add('c');

      expect(container.read(offlineSpentRequestIdsProvider), {'a', 'b', 'c'});
    });
  });

  group('OfflinePaymentStore', () {
    test('round-trips the pending queue', () async {
      final store = OfflinePaymentStore();
      await store.writeQueue([_payment('n1'), _payment('n2', from: 'GX')]);

      final read = await store.readQueue();

      expect(read.map((p) => p.nonce), ['n1', 'n2']);
      expect(read[1].from, 'GX');
    });

    test('spent request ids persist and de-duplicate', () async {
      final store = OfflinePaymentStore();
      await store.markSpent('n1');
      await store.markSpent('n1');
      await store.markSpent('n2');

      expect(await store.spentRequestIds(), {'n1', 'n2'});
    });
  });

  group('PendingOfflinePaymentsNotifier', () {
    test('add persists and is submitted immediately', () async {
      final rig = _Rig();
      final container = rig.build();
      addTearDown(rig.dispose);

      await container.read(pendingOfflinePaymentsProvider.notifier).add(_payment('n1'));

      expect(rig.txApi.submitted.single.idempotencyKey, isNotEmpty);
      expect(rig.txApi.submitted.single.purpose, 'offline_payment');
      expect(rig.txApi.submitted.single.kind, TxKind.classic);
      expect(container.read(pendingOfflinePaymentsProvider).value, isEmpty);
      expect(await OfflinePaymentStore().readQueue(), isEmpty);
    });

    test('the idempotency key is the transaction hash, hex-encoded, stable for the same XDR', () async {
      final xdr = _validXdr();
      final rig = _Rig();
      final container = rig.build();
      addTearDown(rig.dispose);

      final notifier = container.read(pendingOfflinePaymentsProvider.notifier);
      await notifier.add(_payment('n1', signedXdr: xdr));
      // A second, independent payment built from the exact same XDR (as if
      // the receiver's own copy were retried) must key identically.
      await notifier.add(_payment('n2', signedXdr: xdr));

      expect(rig.txApi.submitted, hasLength(2));
      expect(rig.txApi.submitted[0].idempotencyKey, rig.txApi.submitted[1].idempotencyKey);
      expect(rig.txApi.submitted[0].idempotencyKey, startsWith('offline-'));
    });

    test('a network failure keeps the item; retryAll tries again later', () async {
      final rig = _Rig();
      rig.txApi.submitError = ApiException(code: 'network.error', message: 'offline', httpStatus: null);
      final container = rig.build();
      addTearDown(rig.dispose);

      final notifier = container.read(pendingOfflinePaymentsProvider.notifier);
      await notifier.add(_payment('n1'));
      expect(await notifier.future, hasLength(1));

      rig.txApi.submitError = null;
      await notifier.retryAll();

      expect(await notifier.future, isEmpty);
    });

    test('tx.bad_request is terminal — dropped, not retried forever', () async {
      final rig = _Rig();
      rig.txApi.submitError = ApiException(code: 'tx.bad_request', message: 'bad', httpStatus: 400);
      final container = rig.build();
      addTearDown(rig.dispose);

      await container.read(pendingOfflinePaymentsProvider.notifier).add(_payment('n1'));

      expect(await container.read(pendingOfflinePaymentsProvider.notifier).future, isEmpty);
    });

    // Regression test for the "internet comes back but the queue never
    // moves" report: a signed offline payment's sequence number is fixed
    // at build time, so tx_bad_seq (another transaction from this account
    // already advanced past it) can never clear up no matter how many
    // times this exact envelope is retried.
    test('tx_bad_seq is permanently dead — dropped with a clear reason, not retried forever', () async {
      final rig = _Rig();
      rig.txApi.submitError = ApiException(code: 'tx.submit_failed', message: 'tx_bad_seq', httpStatus: 400);
      final container = rig.build();
      addTearDown(rig.dispose);

      await container.read(pendingOfflinePaymentsProvider.notifier).add(_payment('n1'));

      expect(await container.read(pendingOfflinePaymentsProvider.notifier).future, isEmpty);
      expect(
        container.read(offlineQueueErrorProvider),
        contains('could no longer be sent'),
      );
    });

    test('tx_too_late is permanently dead — dropped, not retried forever', () async {
      final rig = _Rig();
      rig.txApi.submitError = ApiException(code: 'tx.submit_failed', message: 'tx_too_late', httpStatus: 400);
      final container = rig.build();
      addTearDown(rig.dispose);

      await container.read(pendingOfflinePaymentsProvider.notifier).add(_payment('n1'));

      expect(await container.read(pendingOfflinePaymentsProvider.notifier).future, isEmpty);
    });

    // A tx.submit_failed reason that ISN'T tx_bad_seq/tx_too_late (e.g. a
    // funding shortfall) can plausibly clear up before the 24h window this
    // queue tracks — it must keep retrying, unlike the two codes above.
    test('a retryable tx.submit_failed keeps the item AND surfaces why — no more silent "waiting"', () async {
      final rig = _Rig();
      rig.txApi.submitError =
          ApiException(code: 'tx.submit_failed', message: 'tx_insufficient_balance', httpStatus: 400);
      final container = rig.build();
      addTearDown(rig.dispose);

      await container.read(pendingOfflinePaymentsProvider.notifier).add(_payment('n1'));

      expect(await container.read(pendingOfflinePaymentsProvider.notifier).future, hasLength(1));
      expect(container.read(offlineQueueErrorProvider), isNotNull);
    });

    test('adding the same nonce twice does not submit it twice', () async {
      final rig = _Rig();
      rig.txApi.submitError = StateError('offline');
      final container = rig.build();
      addTearDown(() => rig.dispose());

      final notifier = container.read(pendingOfflinePaymentsProvider.notifier);
      await notifier.add(_payment('n1'));
      await notifier.add(_payment('n1'));

      expect(await notifier.future, hasLength(1));
      container.dispose();
    });

    test('loads a queue already on disk', () async {
      await OfflinePaymentStore().writeQueue([_payment('n1')]);
      final rig = _Rig();
      final container = rig.build();
      addTearDown(rig.dispose);

      expect(await container.read(pendingOfflinePaymentsProvider.notifier).future, hasLength(1));
    });

    test('once everything is submitted, the retry timer stops (no leaked periodic Timer)', () async {
      final rig = _Rig();
      final container = rig.build();
      final notifier = container.read(pendingOfflinePaymentsProvider.notifier);

      await notifier.add(_payment('n1'));
      expect(await notifier.future, isEmpty);

      container.dispose(); // would throw "Timer still pending" if the loop weren't stopped
    });
  });
}
