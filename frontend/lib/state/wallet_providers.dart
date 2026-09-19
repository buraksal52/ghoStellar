import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'core_providers.dart';

/// Holds the unlocked wallet's [KeyPair] in memory only — never persisted
/// beyond the secure store's encrypted secret seed. Cleared on logout or
/// app restart (the user's device biometric/passcode is what protects the
/// secure store at rest; this provider is just the in-memory unlocked
/// state for the current session).
class WalletState {
  const WalletState({this.keyPair});
  final KeyPair? keyPair;

  bool get isUnlocked => keyPair != null;
  String? get publicKey => keyPair?.accountId;
}

class WalletNotifier extends Notifier<WalletState> {
  @override
  WalletState build() => const WalletState();

  void unlock(KeyPair keyPair) {
    state = WalletState(keyPair: keyPair);
  }

  void lock() {
    state = const WalletState();
  }
}

final walletProvider = NotifierProvider<WalletNotifier, WalletState>(
  WalletNotifier.new,
);

/// Whether a wallet has been created/restored on this device at all
/// (independent of whether it's currently unlocked in memory).
final hasWalletProvider = FutureProvider<bool>((ref) async {
  final store = ref.watch(secureWalletStoreProvider);
  return store.hasWallet();
});
