import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/env.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_provider.dart';
import '../shared/starter_funds_action.dart';
import '../../state/auth_providers.dart';
import '../../state/core_providers.dart';
import '../../state/sync_providers.dart';
import '../../state/wallet_providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _funding = false;

  Future<void> _revealRecoveryPhrase(BuildContext context, WidgetRef ref) async {
    final store = ref.read(secureWalletStoreProvider);
    final mnemonic = await store.readMnemonic();
    if (!context.mounted) return;
    if (mnemonic == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This wallet was restored from a secret key — no phrase to show.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reveal recovery phrase?'),
        content: const Text('Make sure no one else can see your screen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reveal')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery phrase'),
        content: SelectableText(mnemonic, style: const TextStyle(fontFamily: 'monospace')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset wallet?'),
        content: const Text(
          'This removes the wallet from this device. You will need your recovery phrase to restore it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authProvider.notifier).logout();
      if (context.mounted) context.go('/onboarding');
    }
  }

  /// "Get test funds": network fees (`POST /auth/fund` — pay-auth-service is
  /// the one place that touches friendbot, SERVICE.md #24), the USDC
  /// trustline, and a sandbox TRY→USDC bank deposit — so the wallet ends up
  /// with USDC, the app's one unit, instead of a fee balance nobody can see.
  /// The signing overlay shows the steps, the amount that arrived, or why it
  /// failed.
  Future<void> _fundWallet() async {
    if (_funding) return;
    setState(() => _funding = true);
    try {
      await runStarterFunds(ref);
    } finally {
      if (mounted) setState(() => _funding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    final publicKey = ref.watch(walletProvider).publicKey ?? '';
    final networkLabel = Env.networkLabel(ref.watch(networkPassphraseProvider));
    final syncedWithLabel = networkLabel == 'Custom' ? 'a custom network' : 'Stellar $networkLabel';

    Widget row(String label, String value, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 2),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            child: Row(
              children: [
                Expanded(child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                Text(value, style: TextStyle(fontSize: 13, color: c.muted)),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 16, color: c.muted),
              ],
            ),
          ),
        );

    return ListView(
      children: [
        row('Theme', isDark ? 'Dark' : 'Light', () => ref.read(themeModeProvider.notifier).toggle()),
        row('Wallet address', publicKey.isEmpty ? '' : '${publicKey.substring(0, 4)}...${publicKey.substring(publicKey.length - 4)}', () {}),
        row('Recovery phrase', 'View', () => _revealRecoveryPhrase(context, ref)),
        row('Network', networkLabel, () {}),
        if (networkLabel == 'Testnet')
          InkWell(
            onTap: _funding ? null : _fundWallet,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 2),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Get test funds',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: _funding ? c.muted : null,
                      ),
                    ),
                  ),
                  if (_funding)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: c.muted),
                    )
                  else
                    Icon(Icons.chevron_right, size: 16, color: c.muted),
                ],
              ),
            ),
          ),
        row('Reset wallet', '', () => _logout(context, ref)),
        const SizedBox(height: 20),
        Row(
          children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: c.positive, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text('Synced with $syncedWithLabel', style: TextStyle(fontSize: 12, color: c.textSecondary)),
          ],
        ),
      ],
    );
  }
}
