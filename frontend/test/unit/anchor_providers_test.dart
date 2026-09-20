import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/api/endpoints/anchor_api.dart';
import 'package:ghostellar_app/state/anchor_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' hide AnchorTransaction;

import '../support/fakes.dart';

class _FakeChallengeApi extends Fake implements AnchorApi {
  _FakeChallengeApi(this._networkPassphrase);
  final String _networkPassphrase;

  @override
  Future<({String transaction, String networkPassphrase})> challenge(String anchorId) async =>
      (transaction: 'unsigned-xdr', networkPassphrase: _networkPassphrase);

  @override
  Future<String> token(String anchorId, String signedTransactionXdr) async => 'anchor-jwt';
}

void main() {
  // Regression test for SERVICE.md #20: the anchor's own SEP-10 challenge
  // may name a different network than the platform's; the client must sign
  // with THAT network, never silently fall back to its own.
  test('login signs the anchor challenge with the anchor\'s own network_passphrase', () async {
    final keyPair = KeyPair.random();
    final signing = FakeSigning();
    final container = ProviderContainer(overrides: [
      anchorApiProvider.overrideWithValue(_FakeChallengeApi('Public Global Stellar Network ; September 2015')),
      stellarSigningServiceProvider.overrideWithValue(signing),
      walletProvider.overrideWith(() => UnlockedWallet(keyPair)),
    ]);
    addTearDown(container.dispose);

    await container.read(anchorSessionProvider.notifier).login('default');

    expect(container.read(anchorSessionProvider), 'anchor-jwt');
    expect(signing.lastNetworkPassphrase, 'Public Global Stellar Network ; September 2015');
  });

  // SEP-10 makes network_passphrase optional; an anchor that omits it must
  // not break login, and the client falls back to its own network (`null`
  // tells StellarSigningService to use the one it was constructed with).
  test('login falls back to the default network when the anchor omits it', () async {
    final keyPair = KeyPair.random();
    final signing = FakeSigning();
    final container = ProviderContainer(overrides: [
      anchorApiProvider.overrideWithValue(_FakeChallengeApi('')),
      stellarSigningServiceProvider.overrideWithValue(signing),
      walletProvider.overrideWith(() => UnlockedWallet(keyPair)),
    ]);
    addTearDown(container.dispose);

    await container.read(anchorSessionProvider.notifier).login('default');

    expect(signing.lastNetworkPassphrase, isNull);
  });
}
