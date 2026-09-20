// Plain (non-freezed) response models for the anchor's SEP-6 endpoints,
// proxied verbatim by `pay-anchor-service`. Field names follow the anchor's
// snake_case wire format; shapes were checked against the live TR anchor.

/// A labelled line of the anchor's deposit instructions (bank, IBAN,
/// reference). SEP-6 `instructions` is `{key: {value, description}}`.
class Sep6Instruction {
  const Sep6Instruction({required this.key, required this.value, this.description});

  final String key;
  final String value;
  final String? description;

  /// "bank_account_number" -> "Bank account number".
  String get label {
    final spaced = key.replaceAll('_', ' ');
    return spaced.isEmpty ? key : spaced[0].toUpperCase() + spaced.substring(1);
  }
}

class Sep6Deposit {
  const Sep6Deposit({required this.id, required this.how, required this.instructions});

  final String id;

  /// Free-text instructions; the fallback when [instructions] is empty.
  final String how;
  final List<Sep6Instruction> instructions;

  factory Sep6Deposit.fromJson(Map<String, dynamic> json) {
    final raw = json['instructions'];
    final instructions = <Sep6Instruction>[
      if (raw is Map<String, dynamic>)
        for (final e in raw.entries)
          if (e.value is Map<String, dynamic> && (e.value as Map<String, dynamic>)['value'] != null)
            Sep6Instruction(
              key: e.key,
              value: '${(e.value as Map<String, dynamic>)['value']}',
              description: (e.value as Map<String, dynamic>)['description'] as String?,
            ),
    ];
    return Sep6Deposit(
      id: json['id'] as String,
      how: (json['how'] as String?) ?? '',
      instructions: instructions,
    );
  }
}

class Sep6Withdraw {
  const Sep6Withdraw({
    required this.id,
    required this.accountId,
    required this.memoType,
    required this.memo,
    this.message,
  });

  final String id;

  /// Where the user must send the asset on Stellar.
  final String accountId;
  final String memoType;
  final String memo;

  /// The anchor's human summary (rate, payout destination).
  final String? message;

  factory Sep6Withdraw.fromJson(Map<String, dynamic> json) {
    final extra = json['extra_info'];
    return Sep6Withdraw(
      id: json['id'] as String,
      accountId: json['account_id'] as String,
      memoType: (json['memo_type'] as String?) ?? '',
      memo: '${json['memo'] ?? ''}',
      message: extra is Map<String, dynamic> ? extra['message'] as String? : null,
    );
  }
}

class Sep6Transaction {
  const Sep6Transaction({
    required this.id,
    required this.status,
    this.message,
    this.amountIn,
    this.amountOut,
    this.stellarTransactionId,
  });

  final String id;
  final String status;
  final String? message;
  final String? amountIn;
  final String? amountOut;
  final String? stellarTransactionId;

  /// Statuses after which the anchor will not move the transaction again.
  static const terminalStatuses = {
    'completed',
    'refunded',
    'expired',
    'error',
    'no_market',
    'too_small',
    'too_large',
  };

  bool get isTerminal => terminalStatuses.contains(status);
  bool get isCompleted => status == 'completed';

  /// The response wraps the transaction: `{"transaction": {...}}`.
  factory Sep6Transaction.fromJson(Map<String, dynamic> json) {
    final t = (json['transaction'] as Map<String, dynamic>?) ?? json;
    return Sep6Transaction(
      id: t['id'] as String,
      status: t['status'] as String,
      message: t['message'] as String?,
      amountIn: t['amount_in'] as String?,
      amountOut: t['amount_out'] as String?,
      stellarTransactionId: t['stellar_transaction_id'] as String?,
    );
  }
}
