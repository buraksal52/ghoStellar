import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../state/core_providers.dart';

class OnboardingStep1Page extends ConsumerStatefulWidget {
  const OnboardingStep1Page({super.key});

  @override
  ConsumerState<OnboardingStep1Page> createState() => _OnboardingStep1PageState();
}

class _OnboardingStep1PageState extends ConsumerState<OnboardingStep1Page> {
  bool _generating = false;

  Future<void> _createWallet() async {
    setState(() => _generating = true);
    final mnemonicService = ref.read(mnemonicServiceProvider);
    final mnemonic = await mnemonicService.generate12Words();
    final words = mnemonic.split(' ');
    setState(() => _generating = false);
    if (mounted) context.push('/onboarding/recovery', extra: words);
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Text('ghoStellar', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 64),
                  Text('Your money.\nYour keys.',
                      style: Theme.of(context).textTheme.displayLarge),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 300,
                    child: Text(
                      'Non-custodial payments on Stellar.',
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(color: c.textSecondary),
                    ),
                  ),
                ],
              ),
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _generating ? null : _createWallet,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.primary,
                        foregroundColor: c.primaryText,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                      child: _generating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Create Wallet'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed: () => context.push('/onboarding/restore'),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: c.border),
                        foregroundColor: c.text,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                      child: const Text('Restore Wallet'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
