import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/env.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_provider.dart';
import '../../state/auth_providers.dart';
import '../../state/core_providers.dart';
import '../../state/home_providers.dart';
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

  /// Backed by `POST /auth/fund` (pay-auth-service), never a direct
  /// client-side Horizon call — `services/auth/service.go`'s
  /// `FundOwnAccount` is the one place that touches friendbot, matching
  /// the automatic fund-on-login it shares its logic with (SERVICE.md #24).
  /// This is the manual recovery path for a wallet that missed that (or is
  /// already stuck, like the "Submitting to Stellar failed" trustline case).
  Future<void> _fundWallet(BuildContext context) async {
    if (_funding) return;
    setState(() => _funding = true);
    bool funded;
    try {
      funded = await ref.read(authApiProvider).fundTestnetXlm();
    } catch (_) {
      funded = false;
    }
    if (funded) await _refreshBalancesAfterFund();
    if (!context.mounted) return;
    setState(() => _funding = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          funded
              ? 'Funded with XLM for network fees. Add USDC with a bank deposit to send or use the pool.'
              : "Couldn't fund the account right now. Try again in a moment.",
        ),
      ),
    );
  }

  /// Friendbot's transaction is confirmed before `/auth/fund` answers, but
  /// Horizon can take a moment to serve the new account — so the first
  /// re-read may still say "not found". Re-read a few times until it shows.
  Future<void> _refreshBalancesAfterFund() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!mounted) return;
      ref.invalidate(balancesProvider);
      try {
        if ((await ref.read(balancesProvider.future)).exists) return;
      } catch (_) {
        // A failed read is retried like a "not found" one.
      }
      await Future<void>.delayed(const Duration(seconds: 2));
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
            onTap: _funding ? null : () => _fundWallet(context),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 2),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Fund with testnet XLM',
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
