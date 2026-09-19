import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../activity/widgets/activity_item.dart';
import '../../activity/widgets/tx_row.dart';

class RecentActivityList extends StatelessWidget {
  const RecentActivityList({required this.items, super.key});
  final List<ActivityItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Text('No activity yet.', style: TextStyle(color: c.muted)),
        ),
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
          for (var i = 0; i < items.length; i++)
            TxRow(item: items[i], showBottomBorder: i != items.length - 1),
        ],
      ),
    );
  }
}
