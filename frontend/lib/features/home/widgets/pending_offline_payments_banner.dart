import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Surfaces the offline-payment retry queue on Home instead of letting it
/// work (or fail) invisibly — this is the ONLY place a person can see that
/// a payment they sent while offline is still waiting to reach the network,
/// or that one of them was dropped after repeated failures.
class PendingOfflinePaymentsBanner extends StatelessWidget {
  const PendingOfflinePaymentsBanner({required this.count, this.lastError, super.key});
  final int count;
  final String? lastError;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = count == 1
        ? '1 offline payment is waiting to reach the network'
        : '$count offline payments are waiting to reach the network';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: c.infoCard, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (count > 0)
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: c.info, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: c.textSecondary))),
              ],
            ),
          if (lastError != null) ...[
            if (count > 0) const SizedBox(height: 6),
            Text(lastError!, style: TextStyle(fontSize: 12, color: c.negative)),
          ],
        ],
      ),
    );
  }
}
