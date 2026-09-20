import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../state/signing_overlay_provider.dart';

const _labels = {
  SigningStep.preparing: 'Preparing transaction…',
  SigningStep.signing: 'Waiting for signature…',
  SigningStep.submitting: 'Submitting to Stellar…',
  SigningStep.confirming: 'Confirming on-chain…',
};

/// Modal overlay mirroring the design's signing lifecycle card, driven by
/// [signingOverlayProvider]'s real request state.
class SigningOverlay extends ConsumerWidget {
  const SigningOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overlay = ref.watch(signingOverlayProvider);
    if (overlay.step == SigningStep.idle) return const SizedBox.shrink();

    final c = context.colors;
    return Positioned.fill(
      child: ColoredBox(
        color: c.overlay,
        child: Center(
          child: Container(
            width: 310,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (overlay.step == SigningStep.done) ...[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.positive),
                    ),
                    child: Icon(Icons.check, color: c.positive, size: 22),
                  ),
                  const SizedBox(height: 16),
                  Text(overlay.label ?? 'Completed',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () =>
                          ref.read(signingOverlayProvider.notifier).dismiss(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.primary,
                        foregroundColor: c.primaryText,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                      child: const Text('Done'),
                    ),
                  ),
                ] else if (overlay.step == SigningStep.error) ...[
                  Icon(Icons.error_outline, color: c.negative, size: 40),
                  const SizedBox(height: 16),
                  Text(
                    overlay.errorMessage ?? 'Something went wrong.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      onPressed: () =>
                          ref.read(signingOverlayProvider.notifier).dismiss(),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: c.border),
                        foregroundColor: c.text,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                      child: const Text('Dismiss'),
                    ),
                  ),
                ] else ...[
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    overlay.label ?? _labels[overlay.step] ?? '',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontFamily: null),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
