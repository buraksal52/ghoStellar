import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keychain (iOS) / Keystore-backed EncryptedSharedPreferences (Android)
/// storage for everything sensitive: the wallet mnemonic/secret seed and the
/// platform's access/refresh tokens. Nothing here is ever sent anywhere
/// except as explicitly required by a signing/auth flow — the backend never
/// receives the mnemonic or secret seed, only signatures produced from them.
class SecureWalletStore {
  SecureWalletStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kMnemonic = 'wallet.mnemonic';
  static const _kSecretSeed = 'wallet.secretSeed';
  static const _kPublicKey = 'wallet.publicKey';
  static const _kAccessToken = 'auth.accessToken';
  static const _kRefreshToken = 'auth.refreshToken';

  Future<void> saveWallet({
    String? mnemonic,
    required String secretSeed,
    required String publicKey,
  }) async {
    if (mnemonic != null) {
      await _storage.write(key: _kMnemonic, value: mnemonic);
    }
    await _storage.write(key: _kSecretSeed, value: secretSeed);
    await _storage.write(key: _kPublicKey, value: publicKey);
  }

  Future<String?> readMnemonic() => _storage.read(key: _kMnemonic);
  Future<String?> readSecretSeed() => _storage.read(key: _kSecretSeed);
  Future<String?> readPublicKey() => _storage.read(key: _kPublicKey);

  Future<bool> hasWallet() async =>
      (await _storage.read(key: _kSecretSeed)) != null;

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _kAccessToken, value: accessToken);
    await _storage.write(key: _kRefreshToken, value: refreshToken);
  }

  Future<String?> readAccessToken() => _storage.read(key: _kAccessToken);
  Future<String?> readRefreshToken() => _storage.read(key: _kRefreshToken);

  Future<void> clearTokens() async {
    await _storage.delete(key: _kAccessToken);
    await _storage.delete(key: _kRefreshToken);
  }

  /// Full logout / reset wallet. Irreversible — the caller must have
  /// already confirmed with the user (recovery phrase is the only way back).
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
