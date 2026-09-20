import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/pay_asset.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/amount_formatter.dart';
import '../../../state/anchor_providers.dart';
import '../../../state/home_providers.dart';
import '../../../state/sync_providers.dart';

/// The main balance is [PayAsset.configured] (XLM) — the asset cheques and
/// the pool use. It backs network fees too and is never shown as a second,
/// separate amount, so a funded wallet never looks like it can't pay or use
/// the pool. A low fee balance only raises a hint.
///
/// A deployment can also have a separate anchor asset (e.g. USDC, ramped
/// through the bank) that never enters the pool or a cheque — see
/// `AnchorInfo.assetCode`. When the wallet holds any, it gets its own,
/// clearly-labeled second line so that money isn't invisible after a bank
/// deposit.
class BalanceCard extends ConsumerWidget {
  const BalanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final balances = ref.watch(balancesProvider);
    // null until /sync has answered: only an explicit `false` means "no
    // trustline", so the hint never flashes while loading.
    final trustlineReady = ref.watch(syncProvider).value?.trustlineReady;
    final anchor = ref.watch(primaryAnchorProvider);

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
                  _hint(
                    c,
                    'Your wallet isn\'t funded yet — get test funds from Settings →',
                    onTap: () => context.go('/settings'),
                  )
                else if (b.feeBalanceLow)
                  // No amount and no unit: the network fee balance is never
                  // shown as a number, only flagged when it runs low.
                  _hint(
                    c,
                    'Your network fee balance is low — get test funds from Settings →',
                    onTap: () => context.go('/settings'),
                  )
                else if (!b.payAssetIsNative && trustlineReady == false)
                  _hint(
                    c,
                    'Set up ${PayAsset.configured.label} to receive funds →',
                    onTap: () => context.push('/anchor/trustline'),
                  ),
                if (anchor != null && anchor.assetIssuer.isNotEmpty && b.other.containsKey(anchor.assetCode))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: InkWell(
                      onTap: () => context.push('/anchor'),
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(fontSize: 13, color: c.textSecondary),
                          children: [
                            TextSpan(
                              text: '${AmountFormatter.trimTrailingZeros(b.other[anchor.assetCode]!)} ${anchor.assetCode} ',
                              style: TextStyle(fontWeight: FontWeight.w600, color: c.info),
                            ),
                            const TextSpan(text: 'from your bank'),
                          ],
                        ),
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
