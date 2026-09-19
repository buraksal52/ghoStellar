import 'package:intl/intl.dart';

import '../../../core/utils/amount_formatter.dart';
import '../../../data/api/models/cheque_models.dart';
import '../../../data/storage/local_activity_log.dart';

enum ActivityIcon { out, incoming, pool, bank }

class ActivityItem {
  const ActivityItem({
    required this.icon,
    required this.title,
    required this.timestamp,
    required this.amountDisplay,
    required this.isNegative,
    required this.statusLabel,
    required this.category,
  });

  final ActivityIcon icon;
  final String title;
  final DateTime timestamp;
  final String amountDisplay;
  final bool isNegative;
  final String statusLabel;

  /// 'pay' | 'pool' | 'anchor' — matches the design's filter chips.
  final String category;

  String get timeDisplay => DateFormat('MMM d, h:mm a').format(timestamp);

  static ActivityItem fromCheque(Cheque c, {required String myAddress}) {
    final isOut = c.senderAddress == myAddress;
    final amount = AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(c.amountRaw, c.decimals));
    final (label, negative) = switch (c.state) {
      ChequeState.kapandi || ChequeState.onaylandi => ('Completed', isOut),
      ChequeState.iadeEdildi => ('Refunded', false),
      ChequeState.iadeEdilebilir => ('Recoverable', isOut),
      ChequeState.karsiliksiz || ChequeState.hukumsuz => ('Failed', false),
      _ => ('In pool', isOut),
    };
    return ActivityItem(
      icon: isOut ? ActivityIcon.out : ActivityIcon.incoming,
      title: isOut ? 'Cheque Sent' : 'Cheque Received',
      timestamp: DateTime.tryParse(c.updatedAt) ?? DateTime.now(),
      amountDisplay: '${isOut ? '−' : '+'}$amount XLM',
      isNegative: isOut,
      statusLabel: label,
      category: 'pay',
    );
  }

  static ActivityItem fromLocalEvent(LocalActivityEvent e) {
    final isPool = e.kind.startsWith('pool_');
    final isWithdraw = e.kind.endsWith('withdraw');
    return ActivityItem(
      icon: isPool ? ActivityIcon.pool : ActivityIcon.bank,
      title: switch (e.kind) {
        'pool_deposit' => 'Pool Deposit',
        'pool_withdraw' => 'Pool Withdrawal',
        'anchor_deposit' => 'Deposit from Bank',
        _ => 'Withdrawal to Bank',
      },
      timestamp: e.timestamp,
      amountDisplay: '${isWithdraw ? '−' : '+'}${e.amount} ${e.assetCode}',
      isNegative: isWithdraw,
      statusLabel: 'Completed',
      category: isPool ? 'pool' : 'anchor',
    );
  }
}
