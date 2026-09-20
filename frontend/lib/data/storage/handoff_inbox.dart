import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A cheque handoff the receiver accepted while offline (or that failed to
/// claim for some other retryable reason): saved so it survives an app
/// restart and is retried automatically once the network is back. See
/// `state/inbox_providers.dart`.
class PendingHandoff {
  const PendingHandoff({
    required this.chequeId,
    required this.from,
    this.amount,
    this.nonce,
    required this.receivedAt,
  });

  final String chequeId;
  final String from;
  final String? amount;
  final String? nonce;
  final DateTime receivedAt;

  Map<String, dynamic> toJson() => {
        'chequeId': chequeId,
        'from': from,
        'amount': amount,
        'nonce': nonce,
        'receivedAt': receivedAt.toIso8601String(),
      };

  factory PendingHandoff.fromJson(Map<String, dynamic> json) => PendingHandoff(
        chequeId: json['chequeId'] as String,
        from: json['from'] as String,
        amount: json['amount'] as String?,
        nonce: json['nonce'] as String?,
        receivedAt: DateTime.parse(json['receivedAt'] as String),
      );
}

/// Persists the pending-handoff list across restarts. A device-local,
/// best-effort record — the server's cheque state is still the only
/// authority (D6); losing this list only means falling back to `/sync`
/// polling or the manual "Claim" button.
class HandoffInboxStore {
  static const _key = 'ghoStellarPendingHandoffs';

  Future<List<PendingHandoff>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) => PendingHandoff.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> writeAll(List<PendingHandoff> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [for (final h in items) jsonEncode(h.toJson())]);
  }
}
