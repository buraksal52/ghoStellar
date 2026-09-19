import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// Real BIP-39 mnemonic generation + SEP-0005 (`m/44'/148'/0'`) key
/// derivation — nothing here is hardcoded or mocked. Backed directly by
/// `stellar_flutter_sdk`'s `Wallet`, which implements both.
class MnemonicService {
  const MnemonicService();

  Future<String> generate12Words() => Wallet.generate12WordsMnemonic();

  Future<bool> isValid(String mnemonic) => Wallet.validate(mnemonic);

  /// Derives the first Stellar keypair (index 0) from a validated mnemonic.
  Future<KeyPair> keypairFromMnemonic(String mnemonic) async {
    final wallet = await Wallet.from(mnemonic);
    return wallet.getKeyPair(index: 0);
  }
}
