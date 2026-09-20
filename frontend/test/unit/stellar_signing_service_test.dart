import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/stellar/mnemonic_service.dart';
import 'package:ghostellar_app/data/stellar/stellar_signing_service.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

const _testnet = 'Test SDF Network ; September 2015';
const _pubnet = 'Public Global Stellar Network ; September 2015';

String _unsignedXdr(KeyPair source) => TransactionBuilder(Account(source.accountId, BigInt.from(5)))
    .addOperation(BumpSequenceOperationBuilder(BigInt.from(6)).build())
    .build()
    .toEnvelopeXdrBase64();

void main() {
  const mnemonicService = MnemonicService();
  const signingService = StellarSigningService();

  group('MnemonicService', () {
    test('generates a valid 12-word BIP-39 mnemonic', () async {
      final mnemonic = await mnemonicService.generate12Words();
      expect(mnemonic.split(' '), hasLength(12));
      expect(await mnemonicService.isValid(mnemonic), isTrue);
    });

    test('rejects an invalid mnemonic', () async {
      expect(await mnemonicService.isValid('not a real mnemonic phrase'), isFalse);
    });

    test('derives the same SEP-0005 keypair from the same mnemonic every time', () async {
      final mnemonic = await mnemonicService.generate12Words();
      final a = await mnemonicService.keypairFromMnemonic(mnemonic);
      final b = await mnemonicService.keypairFromMnemonic(mnemonic);
      expect(a.accountId, b.accountId);
      expect(a.accountId, startsWith('G'));
    });
  });

  group('StellarSigningService', () {
    test('restores the same public key from a keypair\'s own secret seed', () async {
      final mnemonic = await mnemonicService.generate12Words();
      final original = await mnemonicService.keypairFromMnemonic(mnemonic);
      final restored = signingService.keypairFromSecretSeed(original.secretSeed);
      expect(restored.accountId, original.accountId);
    });

    // Regression test for SERVICE.md #20: a Stellar signature commits to
    // the network id (sha256 of the passphrase), so the same XDR signed for
    // two different networks must produce two different — and each
    // internally consistent — signed envelopes. Signing with the wrong
    // passphrase never throws; it silently produces a signature Horizon
    // will reject as tx_bad_auth, which is exactly the failure mode this
    // fix closes.
    test('signTransactionXdr binds the signature to the passphrase used', () {
      final signer = KeyPair.random();
      final unsigned = _unsignedXdr(signer);

      final testnetSigned = signingService.signTransactionXdr(unsigned, signer, networkPassphrase: _testnet);
      final pubnetSigned = signingService.signTransactionXdr(unsigned, signer, networkPassphrase: _pubnet);

      expect(testnetSigned, isNot(equals(pubnetSigned)));

      final testnetTx = AbstractTransaction.fromEnvelopeXdrString(testnetSigned) as Transaction;
      final pubnetTx = AbstractTransaction.fromEnvelopeXdrString(pubnetSigned) as Transaction;
      expect(testnetTx.signatures.first.signature, isNot(equals(pubnetTx.signatures.first.signature)));
    });

    test('signTransactionXdr defaults to the passphrase given at construction', () {
      final signer = KeyPair.random();
      final unsigned = _unsignedXdr(signer);
      const custom = StellarSigningService(networkPassphrase: _pubnet);

      final viaDefault = custom.signTransactionXdr(unsigned, signer);
      final viaOverride = signingService.signTransactionXdr(unsigned, signer, networkPassphrase: _pubnet);

      expect(viaDefault, viaOverride);
    });
  });
}
