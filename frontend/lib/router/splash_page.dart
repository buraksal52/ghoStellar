import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/core_providers.dart';
import '../state/wallet_providers.dart';

/// Cold-start entry point: checks whether a wallet already exists on this
/// device. If so, silently restores the in-memory keypair from the secure
/// store (protected at rest by the OS Keychain/Keystore — no mnemonic
/// re-entry needed on every launch) and proceeds to the auth gate. If not,
/// routes to onboarding.
class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({super.key});

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final store = ref.read(secureWalletStoreProvider);
    final secretSeed = await store.readSecretSeed();
    if (secretSeed == null) {
      if (mounted) context.go('/onboarding');
      return;
    }
    final signing = ref.read(stellarSigningServiceProvider);
    final keyPair = signing.keypairFromSecretSeed(secretSeed);
    ref.read(walletProvider.notifier).unlock(keyPair);
    if (mounted) context.go('/auth-gate');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
