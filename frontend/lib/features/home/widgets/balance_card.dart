import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/amount_formatter.dart';
import '../../../state/home_providers.dart';

class BalanceCard extends ConsumerWidget {
  const BalanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final balances = ref.watch(balancesProvider);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Available Balance',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary)),
          const SizedBox(height: 8),
          balances.when(
            data: (b) => RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.displayLarge,
                children: [
                  TextSpan(text: '${AmountFormatter.trimTrailingZeros(b.native)} '),
                  TextSpan(
                    text: 'XLM',
                    style: TextStyle(fontSize: 18, color: c.info, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            loading: () => SizedBox(
              height: 36,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.muted),
                ),
              ),
            ),
            error: (e, _) => Text('—', style: Theme.of(context).textTheme.displayLarge),
          ),
          balances.maybeWhen(
            data: (b) {
              final usdc = b.other['USDC'];
              if (usdc == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Container(
                  padding: const EdgeInsets.only(top: 14),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: c.border)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('USDC', style: TextStyle(color: c.textSecondary, fontSize: 14)),
                      Text(AmountFormatter.trimTrailingZeros(usdc), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
