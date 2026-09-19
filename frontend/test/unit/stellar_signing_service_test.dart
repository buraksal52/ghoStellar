import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/stellar/mnemonic_service.dart';
import 'package:ghostellar_app/data/stellar/stellar_signing_service.dart';

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
  });
}
