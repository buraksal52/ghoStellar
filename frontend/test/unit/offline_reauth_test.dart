import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/config/pay_asset.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/data/api/endpoints/tx_api.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';
import 'package:ghostellar_app/data/storage/offline_payment_store.dart';
import 'package:ghostellar_app/data/stellar/offline_account_cache.dart';
import 'package:ghostellar_app/data/stellar/offline_payment_builder.dart';
import 'package:ghostellar_app/state/auth_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/offline_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

/// A `POST /tx/submit` that answers `auth.invalid_token` until the session has
/// been re-established, exactly like a gateway rejecting a cleared token.
class _SessionTx extends Fake implements TxApi {
  _SessionTx(this.hasSession);
  final bool Function() hasSession;
  int attempts = 0;

  @override
  Future<SubmitResponse> submit({
    required String idempotencyKey,
    required String purpose,
    required TxKind kind,
    required String xdr,
  }) async {
    attempts++;
    if (!hasSession()) throw ApiException(code: 'auth.invalid_token', message: 'expired', httpStatus: 401);
    return const SubmitResponse(hash: 'h', successful: true, replayed: false);
  }
}

class _Auth extends AuthNotifier {
  _Auth({required this.onEnsure});
  final void Function() onEnsure;
  int ensureCalls = 0;

  // The stale cache: "logged in", though the tokens are gone.
  @override
  Future<bool> build() async => true;

  @override
  Future<void> ensureSession() async {
    ensureCalls++;
    onEnsure();
  }
}

PendingOfflinePayment _payment() {
  final s = KeyPair.random();
  return PendingOfflinePayment(
    signedXdr: const OfflinePaymentBuilder().buildAndSign(
      sender: s,
      snapshot: OfflineAccountSnapshot(
        accountId: s.accountId,
        sequence: BigInt.from(10),
        availableRaw: '100000000',
        decimals: 7,
        fetchedAt: DateTime.utc(2026, 9, 20),
      ),
      destination: KeyPair.random().accountId,
      amount: '5',
      nonce: 'n1',
      asset: const PayAsset(code: 'USDC', issuer: 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5'),
      networkPassphrase: 'Test SDF Network ; September 2015',
    ),
    nonce: 'n1',
    from: s.accountId,
    amountRaw: '50000000',
    decimals: 7,
    receivedAt: DateTime.utc(2026, 9, 20),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer build({required _SessionTx tx, required _Auth auth, FakeSyncNotifier? sync}) {
    final c = ProviderContainer(overrides: <Override>[
      txApiProvider.overrideWithValue(tx),
      authProvider.overrideWith(() => auth),
      horizonReadServiceProvider.overrideWithValue(FakeHorizonReadService()),
      secureWalletStoreProvider.overrideWithValue(FakeSecureWalletStore(publicKey: 'GOTHER')),
      syncProvider.overrideWith(() => sync ?? FakeSyncNotifier(const [])),
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('a 401 while settling re-establishes the session once and the payment then goes through', () async {
    var session = false;
    final tx = _SessionTx(() => session);
    final auth = _Auth(onEnsure: () => session = true);
    final c = build(tx: tx, auth: auth);

    await c.read(pendingOfflinePaymentsProvider.notifier).add(_payment());

    expect(auth.ensureCalls, 1);
    expect(tx.attempts, 2, reason: 'the 401, then one retry after logging in again');
    expect(c.read(pendingOfflinePaymentsProvider).value, isEmpty);
    expect(c.read(offlineQueueErrorProvider), isNull);
  });

  test('if logging in again does not help, the payment stays queued with a reason — no loop within one pass', () async {
    final tx = _SessionTx(() => false);
    final auth = _Auth(onEnsure: () {});
    final c = build(tx: tx, auth: auth);

    await c.read(pendingOfflinePaymentsProvider.notifier).add(_payment());

    expect(auth.ensureCalls, 1);
    expect(tx.attempts, 2);
    expect(c.read(pendingOfflinePaymentsProvider).value, hasLength(1));
    expect(c.read(offlineQueueErrorProvider), contains('sign in again'));
  });

  test('a payment that finally settles refreshes /sync so the UI does not keep showing old balances', () async {
    final sync = FakeSyncNotifier(const []);
    final c = build(tx: _SessionTx(() => true), auth: _Auth(onEnsure: () {}), sync: sync);

    await c.read(pendingOfflinePaymentsProvider.notifier).add(_payment());

    expect(sync.refreshes, greaterThanOrEqualTo(1));
  });
}
