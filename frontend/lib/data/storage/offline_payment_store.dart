import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A verified offline payment (`OfflinePaymentVerifier` already checked it)
/// waiting to reach the network: it needs exactly one `POST /tx/submit`,
/// which either the receiver or the sender may end up sending first — see
/// `state/offline_providers.dart` for the idempotency key that makes that
/// safe.
class PendingOfflinePayment {
  const PendingOfflinePayment({
    required this.signedXdr,
    required this.nonce,
    required this.from,
    required this.amountRaw,
    required this.decimals,
    required this.receivedAt,
  });

  final String signedXdr;
  final String nonce;
  final String from;
  final String amountRaw;
  final int decimals;
  final DateTime receivedAt;

  Map<String, dynamic> toJson() => {
        'signedXdr': signedXdr,
        'nonce': nonce,
        'from': from,
        'amountRaw': amountRaw,
        'decimals': decimals,
        'receivedAt': receivedAt.toIso8601String(),
      };

  factory PendingOfflinePayment.fromJson(Map<String, dynamic> json) => PendingOfflinePayment(
        signedXdr: json['signedXdr'] as String,
        nonce: json['nonce'] as String,
        from: json['from'] as String,
        amountRaw: json['amountRaw'] as String,
        decimals: json['decimals'] as int,
        receivedAt: DateTime.parse(json['receivedAt'] as String),
      );
}

/// Persists the pending-offline-payment queue and, separately, which
/// payment-request ids this device has already answered offline.
///
/// That second set exists because the usual "already paid" check
/// (`paidRequestIdsProvider`) reads `/sync`'s cheques — an offline payment
/// is never a cheque, so it would never show up there. Recorded the moment
/// the payment is *built and signed* (irrevocable client-side, same
/// principle as marking a cheque's request spent at creation, not at scan
/// time) — kept forever, not just while pending, since the point is exactly
/// to remember a request was already paid even after it has been submitted.
class OfflinePaymentStore {
  static const _queueKey = 'ghoStellarPendingOfflinePayments';
  static const _spentKey = 'ghoStellarOfflineSpentRequestIds';

  Future<List<PendingOfflinePayment>> readQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_queueKey) ?? const [];
    return raw
        .map((s) => PendingOfflinePayment.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> writeQueue(List<PendingOfflinePayment> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_queueKey, [for (final p in items) jsonEncode(p.toJson())]);
  }

  Future<Set<String>> spentRequestIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_spentKey) ?? const []).toSet();
  }

  Future<void> markSpent(String requestId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_spentKey) ?? const [];
    if (current.contains(requestId)) return;
    await prefs.setStringList(_spentKey, [...current, requestId]);
  }
}
