import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import 'activity_item.dart';

class TxRow extends StatelessWidget {
  const TxRow({required this.item, this.showBottomBorder = true, super.key});
  final ActivityItem item;
  final bool showBottomBorder;

  IconData get _icon => switch (item.icon) {
        ActivityIcon.out => Icons.arrow_upward_rounded,
        ActivityIcon.incoming => Icons.arrow_downward_rounded,
        ActivityIcon.pool => Icons.swap_vert_rounded,
        ActivityIcon.bank => Icons.account_balance_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final statusColor = switch (item.statusLabel) {
      'Completed' => c.positive,
      'In pool' => c.info,
      'Failed' => c.negative,
      _ => c.muted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        border: showBottomBorder ? Border(bottom: BorderSide(color: c.border)) : null,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.surfaceRaised,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(_icon, size: 14, color: c.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(item.timeDisplay, style: TextStyle(fontSize: 12, color: c.muted)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                item.amountDisplay,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: item.isNegative ? c.text : c.positive,
                ),
              ),
              const SizedBox(height: 2),
              Text(item.statusLabel, style: TextStyle(fontSize: 11, color: statusColor)),
            ],
          ),
        ],
      ),
    );
  }
}
