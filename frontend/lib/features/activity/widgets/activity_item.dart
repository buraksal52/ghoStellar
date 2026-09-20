import 'package:intl/intl.dart';

import '../../../core/config/pay_asset.dart';
import '../../../core/utils/amount_formatter.dart';
import '../../../core/utils/anchor_status.dart';
import '../../../data/api/models/anchor_models.dart';
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
      // Cheques are written in the app's one asset, never in XLM.
      amountDisplay: '${isOut ? '−' : '+'}$amount ${PayAsset.configured.label}',
      isNegative: isOut,
      statusLabel: label,
      category: 'pay',
    );
  }

  /// A pool event from this device's own log. Bank transfers are not in that
  /// log — the backend keeps their ledger, see [fromAnchorTransaction].
  static ActivityItem fromLocalEvent(LocalActivityEvent e) {
    final isWithdraw = e.kind.endsWith('withdraw');
    return ActivityItem(
      icon: ActivityIcon.pool,
      title: isWithdraw ? 'Pool Withdrawal' : 'Pool Deposit',
      timestamp: e.timestamp,
      amountDisplay: '${isWithdraw ? '−' : '+'}${e.amount} ${e.assetCode}',
      isNegative: isWithdraw,
      statusLabel: 'Completed',
      category: 'pool',
    );
  }

  /// A bank deposit/withdrawal from the backend's anchor ledger. Every row
  /// counts, not just finished ones: one that is still waiting on the user's
  /// wire, or that failed, is exactly what they come here to look for.
  static ActivityItem fromAnchorTransaction(AnchorTransaction t) {
    final isDeposit = t.kind == 'deposit';
    final raw = t.amount;
    final decimals = t.decimals;
    // The ledger row is opened before any amount is known (and `amount` is
    // omitted until then), so a pending transfer legitimately has none.
    final hasAmount = raw != null && raw.isNotEmpty && decimals != null;
    final amount = hasAmount ? AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(raw, decimals)) : null;
    return ActivityItem(
      icon: ActivityIcon.bank,
      title: isDeposit ? 'Deposit from Bank' : 'Withdrawal to Bank',
      timestamp: DateTime.tryParse(t.updatedAt) ?? DateTime.tryParse(t.startedAt) ?? DateTime.now(),
      amountDisplay: amount == null ? '' : '${isDeposit ? '+' : '−'}$amount ${PayAsset.configured.label}',
      isNegative: !isDeposit,
      statusLabel: anchorStatusShortLabel(t.state),
      category: 'anchor',
    );
  }
}
