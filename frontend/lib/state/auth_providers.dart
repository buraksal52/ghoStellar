import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_providers.dart';
import 'wallet_providers.dart';

/// Drives the platform's own SEP-10 login (distinct from any anchor's own
/// SEP-10 — see `anchor_providers.dart`). Requires the wallet to already be
/// unlocked (`walletProvider.keyPair` set) before calling [login].
class AuthNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final store = ref.watch(secureWalletStoreProvider);
    final token = await store.readAccessToken();
    return token != null;
  }

  Future<void> login() async {
    final wallet = ref.read(walletProvider);
    final keyPair = wallet.keyPair;
    if (keyPair == null) {
      throw StateError('Wallet must be unlocked before login.');
    }
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final authApi = ref.read(authApiProvider);
      final signing = ref.read(stellarSigningServiceProvider);
      final store = ref.read(secureWalletStoreProvider);

      final challenge = await authApi.challenge(keyPair.accountId);
      final signedXdr =
          signing.signTransactionXdr(challenge.transaction, keyPair);
      final pair = await authApi.token(signedXdr);
      await store.saveTokens(
        accessToken: pair.accessToken,
        refreshToken: pair.refreshToken,
      );
      return true;
    });
  }

  Future<void> logout() async {
    final store = ref.read(secureWalletStoreProvider);
    await store.clearAll();
    ref.read(walletProvider.notifier).lock();
    state = const AsyncData(false);
  }
}

final authProvider = AsyncNotifierProvider<AuthNotifier, bool>(AuthNotifier.new);
