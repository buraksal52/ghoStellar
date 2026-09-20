import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Client-observed-only log of pool actions this device has successfully
/// submitted. There is no backend history endpoint for these (only a
/// current-state snapshot), so this is a known, accepted gap — not
/// authoritative, and lost on reinstall or a second device. Cheque history
/// comes from `/sync` and bank transfers from the anchor ledger
/// (`GET /anchors/{id}/transactions`); neither needs this.
///
/// Pool events are always in the platform's one asset ([PayAsset.configured]),
/// never the anchor's — so the asset is derived at read time
/// (`ActivityItem.fromLocalEvent`), not stored here. It used to be, and older
/// records may still carry a now-ignored `assetCode` key.
///
/// Builds before that change also wrote `anchor_deposit`/`anchor_withdraw`
/// events; they may still be stored, and readers must ignore them.
class LocalActivityEvent {
  const LocalActivityEvent({
    required this.kind, // 'pool_deposit' | 'pool_withdraw'
    required this.amount,
    required this.timestamp,
  });

  final String kind;
  final String amount;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'amount': amount,
        'timestamp': timestamp.toIso8601String(),
      };

  factory LocalActivityEvent.fromJson(Map<String, dynamic> json) => LocalActivityEvent(
        kind: json['kind'] as String,
        amount: json['amount'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

class LocalActivityLog {
  static const _key = 'ghoStellarLocalActivity';

  Future<List<LocalActivityEvent>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) => LocalActivityEvent.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> append(LocalActivityEvent event) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    await prefs.setStringList(_key, [...raw, jsonEncode(event.toJson())]);
  }
}
