import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../state/activity_providers.dart';
import 'widgets/activity_item.dart';
import 'widgets/tx_row.dart';

const _filters = ['All', 'Sent', 'Received', 'Pool', 'Bank'];

class ActivityPage extends ConsumerStatefulWidget {
  const ActivityPage({super.key});

  @override
  ConsumerState<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends ConsumerState<ActivityPage> {
  String _filter = 'All';

  bool _matches(ActivityItem item) {
    return switch (_filter) {
      'Sent' => item.category == 'pay' && item.isNegative,
      'Received' => item.category == 'pay' && !item.isNegative,
      'Pool' => item.category == 'pool',
      'Bank' => item.category == 'anchor',
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = ref.watch(activityItemsProvider);

    return ListView(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final f in _filters)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                    selectedColor: c.primary,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _filter == f ? c.primaryText : c.textSecondary,
                    ),
                    backgroundColor: c.surface,
                    side: BorderSide(color: c.border),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        items.when(
          data: (list) {
            final filtered = list.where(_matches).toList();
            if (filtered.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text('No activity here yet.', style: TextStyle(color: c.muted))),
              );
            }
            return Container(
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < filtered.length; i++)
                    TxRow(item: filtered[i], showBottomBorder: i != filtered.length - 1),
                ],
              ),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not load activity.', style: TextStyle(color: c.muted)),
          ),
        ),
      ],
    );
  }
}
