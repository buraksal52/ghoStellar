import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';

class PendingClaimsBanner extends StatelessWidget {
  const PendingClaimsBanner({required this.count, super.key});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = count == 1 ? '1 cheque waiting for you to claim' : '$count cheques waiting for you to claim';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: c.infoCard, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c.info, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: c.textSecondary))),
          TextButton(
            onPressed: () => context.push('/receive'),
            child: Text('Review →', style: TextStyle(color: c.info, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
