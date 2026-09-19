import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/theme/app_colors.dart';
import '../../state/core_providers.dart';
import '../../state/wallet_providers.dart';

/// Accepts either a 12-word SEP-0005 mnemonic or a raw Stellar secret seed
/// (S...) — whichever the user has. Both re-derive the exact same keypair
/// path the app would have generated itself, nothing here is mocked.
class RestoreWalletPage extends ConsumerStatefulWidget {
  const RestoreWalletPage({super.key});

  @override
  ConsumerState<RestoreWalletPage> createState() => _RestoreWalletPageState();
}

class _RestoreWalletPageState extends ConsumerState<RestoreWalletPage> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _restore() async {
    final input = _controller.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final signing = ref.read(stellarSigningServiceProvider);
      final mnemonicService = ref.read(mnemonicServiceProvider);
      final store = ref.read(secureWalletStoreProvider);

      KeyPair keyPair;
      String? mnemonic;
      if (input.startsWith('S') && input.length == 56) {
        keyPair = signing.keypairFromSecretSeed(input);
      } else {
        if (!await mnemonicService.isValid(input)) {
          throw const FormatException('That recovery phrase doesn\'t look valid.');
        }
        mnemonic = input;
        keyPair = await mnemonicService.keypairFromMnemonic(input);
      }

      await store.saveWallet(
        mnemonic: mnemonic,
        secretSeed: keyPair.secretSeed,
        publicKey: keyPair.accountId,
      );
      ref.read(walletProvider.notifier).unlock(keyPair);
      if (mounted) context.go('/auth-gate');
    } catch (e) {
      setState(() => _error = e is FormatException
          ? e.message
          : 'Could not restore that wallet. Check the phrase or key and try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(title: const Text('Restore Wallet')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(26, 16, 26, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your 12-word recovery phrase or your Stellar secret key (S...).',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              maxLines: 4,
              decoration: const InputDecoration(hintText: 'word word word ... or S...'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: c.negative, fontSize: 13)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _loading ? null : _restore,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: c.primaryText,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Restore'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
