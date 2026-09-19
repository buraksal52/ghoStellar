import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../state/core_providers.dart';
import '../../state/wallet_providers.dart';

class OnboardingStep2Page extends ConsumerStatefulWidget {
  const OnboardingStep2Page({required this.words, super.key});
  final List<String> words;

  @override
  ConsumerState<OnboardingStep2Page> createState() => _OnboardingStep2PageState();
}

class _OnboardingStep2PageState extends ConsumerState<OnboardingStep2Page> {
  bool _confirmed = false;
  bool _saving = false;

  Future<void> _continue() async {
    setState(() => _saving = true);
    final mnemonic = widget.words.join(' ');
    final mnemonicService = ref.read(mnemonicServiceProvider);
    final keyPair = await mnemonicService.keypairFromMnemonic(mnemonic);
    final store = ref.read(secureWalletStoreProvider);
    await store.saveWallet(
      mnemonic: mnemonic,
      secretSeed: keyPair.secretSeed,
      publicKey: keyPair.accountId,
    );
    ref.read(walletProvider.notifier).unlock(keyPair);
    if (mounted) context.go('/auth-gate');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 32, 26, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Save your recovery phrase',
                          style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 8),
                      Text(
                        "Write these 12 words down and store them somewhere safe. "
                        'Anyone with this phrase can access your funds.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: c.textSecondary),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: c.surface,
                          border: Border.all(color: c.border),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 10,
                            childAspectRatio: 3.2,
                          ),
                          itemCount: widget.words.length,
                          itemBuilder: (context, i) => Row(
                            children: [
                              SizedBox(
                                width: 16,
                                child: Text('${i + 1}',
                                    style: TextStyle(color: c.muted, fontSize: 13)),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  widget.words[i],
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _confirmed,
                            onChanged: (v) => setState(() => _confirmed = v ?? false),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                "I've saved my recovery phrase somewhere safe.",
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: c.textSecondary, fontSize: 13),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: (_confirmed && !_saving) ? _continue : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.primary,
                    foregroundColor: c.primaryText,
                    disabledBackgroundColor: c.primaryDim,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
