import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/trustline_setup.dart';

class TrustlineSetupPage extends ConsumerWidget {
  const TrustlineSetupPage({super.key});

  Future<void> _signAndSetUp(WidgetRef ref, BuildContext context) async {
    final setup = ref.read(trustlineSetupProvider);
    final overlay = ref.read(signingOverlayProvider.notifier);

    await overlay.run((report) async {
      await setup.run(report: report);
      if (context.mounted) context.pop();
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return ListView(
      children: [
        const SizedBox(height: 12),
        Column(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: c.surfaceRaised,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.shield_outlined, color: c.info, size: 22),
            ),
            const SizedBox(height: 14),
            Text('Set up USDC', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            SizedBox(
              width: 280,
              child: Text(
                'USDC must be enabled on your Stellar account before it can be held or received.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.5, color: c.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Network reserve', style: TextStyle(fontSize: 13, color: c.textSecondary)),
              const Text('Held while enabled', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: () => _signAndSetUp(ref, context),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.primary,
              foregroundColor: c.primaryText,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Sign & Set Up'),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text('One-time Stellar account setup.', style: TextStyle(fontSize: 12, color: c.muted)),
        ),
      ],
    );
  }
}
