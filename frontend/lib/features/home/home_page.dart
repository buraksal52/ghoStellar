import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../state/activity_providers.dart';
import '../../state/sync_providers.dart';
import 'widgets/action_tile.dart';
import 'widgets/balance_card.dart';
import 'widgets/pending_claims_banner.dart';
import 'widgets/recent_activity_list.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final pendingClaims = ref.watch(pendingClaimsProvider);

    return RefreshIndicator(
      onRefresh: () => ref.read(syncProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          Text(
            'WALLET',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: c.muted,
            ),
          ),
          const SizedBox(height: 10),
          const BalanceCard(),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: ActionTile(
                  icon: Icons.north_rounded,
                  label: 'Send',
                  background: c.tileSend,
                  iconColor: c.tileSendIcon,
                  onTap: () => context.push('/send'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ActionTile(
                  icon: Icons.south_rounded,
                  label: 'Receive',
                  background: c.tileReceive,
                  iconColor: c.tileReceiveIcon,
                  onTap: () => context.push('/receive'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ActionTile(
                  icon: Icons.swap_vert_rounded,
                  label: 'Pool',
                  background: c.tilePool,
                  iconColor: c.tilePoolIcon,
                  onTap: () => context.push('/pool'),
                ),
              ),
            ],
          ),
          if (pendingClaims.isNotEmpty) ...[
            const SizedBox(height: 22),
            PendingClaimsBanner(count: pendingClaims.length),
          ],
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent activity', style: Theme.of(context).textTheme.titleMedium),
              TextButton(
                onPressed: () => context.push('/activity'),
                child: Text('See all', style: TextStyle(color: c.info, fontSize: 13)),
              ),
            ],
          ),
          Consumer(
            builder: (context, ref, _) {
              final items = ref.watch(activityItemsProvider);
              return items.when(
                data: (list) => RecentActivityList(items: list.take(3).toList()),
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Could not load activity.', style: TextStyle(color: c.muted)),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
