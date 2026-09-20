import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/pay_asset.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/amount_formatter.dart';
import '../../../state/home_providers.dart';
import '../../../state/sync_providers.dart';

/// The one balance the app talks about is [PayAsset.configured] (USDC). XLM only
/// backs network fees, so it is a secondary "fee balance" line — showing it
/// as the headline number made a funded-but-USDC-less wallet look like it
/// could pay or use the pool.
class BalanceCard extends ConsumerWidget {
  const BalanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final balances = ref.watch(balancesProvider);
    // null until /sync has answered: only an explicit `false` means "no
    // trustline", so the hint never flashes while loading.
    final trustlineReady = ref.watch(syncProvider).value?.trustlineReady;

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
            data: (b) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: Theme.of(context).textTheme.displayLarge,
                    children: [
                      TextSpan(text: '${AmountFormatter.trimTrailingZeros(b.payAsset)} '),
                      TextSpan(
                        text: PayAsset.configured.label,
                        style: TextStyle(fontSize: 18, color: c.info, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                if (!b.exists)
                  _hint(c, 'Your wallet isn\'t funded yet — fund it from Settings.')
                else if (!b.payAssetIsNative && trustlineReady == false)
                  _hint(
                    c,
                    'Set up ${PayAsset.configured.label} to receive funds →',
                    onTap: () => context.push('/anchor/trustline'),
                  ),
                if (b.exists && !b.payAssetIsNative)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Container(
                      padding: const EdgeInsets.only(top: 14),
                      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Network fee balance', style: TextStyle(color: c.textSecondary, fontSize: 14)),
                          Text('${AmountFormatter.trimTrailingZeros(b.native)} XLM',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  ),
              ],
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
            error: (e, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('—', style: Theme.of(context).textTheme.displayLarge),
                _hint(
                  c,
                  'Couldn\'t load your balance. Tap to retry.',
                  onTap: () => ref.invalidate(balancesProvider),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint(AppColors c, String text, {VoidCallback? onTap}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: InkWell(
          onTap: onTap,
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: onTap == null ? c.muted : c.info),
          ),
        ),
      );
}
