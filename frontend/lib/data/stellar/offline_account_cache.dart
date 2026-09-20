import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/config/pay_asset.dart';

/// The last-known state of the wallet's own account, cached whenever the app
/// is online, so an offline payment can be built (and its plausibility
/// checked) without a network call: a sequence number to build the next
/// transaction on, and how much of the configured [PayAsset] was available.
///
/// This is a plain read-cache, not a source of truth — it is only ever used
/// to build a transaction the network will itself accept or reject once
/// submitted (D6, same principle as the rest of the app). Its only job is
/// keeping the sender from signing a payment that is obviously unpayable.
class OfflineAccountSnapshot {
  const OfflineAccountSnapshot({
    required this.accountId,
    required this.sequence,
    required this.availableRaw,
    required this.decimals,
    required this.fetchedAt,
  });

  final String accountId;
  final BigInt sequence;

  /// Raw integer units of the configured asset (`money.Amount` shape) —
  /// never a double.
  final String availableRaw;
  final int decimals;
  final DateTime fetchedAt;

  /// Reads the sequence number and the configured asset's balance out of a
  /// live Horizon [AccountResponse]. Returns null if the account doesn't
  /// hold the configured asset at all (no trustline set up yet — nothing
  /// meaningful to cache).
  static OfflineAccountSnapshot? fromAccount(
    AccountResponse account,
    PayAsset asset,
    int decimals, {
    DateTime? now,
  }) {
    for (final b in account.balances) {
      final isNative = b.assetType == Asset.TYPE_NATIVE;
      final matches = asset.isNative
          ? isNative
          : !isNative && b.assetCode == asset.code && b.assetIssuer == asset.issuer;
      if (!matches) continue;
      final raw = _toRaw(b.balance, decimals);
      if (raw == null) continue;
      return OfflineAccountSnapshot(
        accountId: account.accountId,
        sequence: account.sequenceNumber,
        availableRaw: raw,
        decimals: decimals,
        fetchedAt: now ?? DateTime.now(),
      );
    }
    return null;
  }

  /// This snapshot with one payment of [amountRaw] deducted and the sequence
  /// advanced by one — so a second offline payment built in the same offline
  /// stretch, before either reaches the network, isn't built against funds
  /// or a sequence number already committed to the first.
  OfflineAccountSnapshot reserve(String amountRaw) {
    final left = BigInt.parse(availableRaw) - BigInt.parse(amountRaw);
    return OfflineAccountSnapshot(
      accountId: accountId,
      sequence: sequence + BigInt.one,
      availableRaw: left < BigInt.zero ? '0' : left.toString(),
      decimals: decimals,
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'sequence': sequence.toString(),
        'availableRaw': availableRaw,
        'decimals': decimals,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory OfflineAccountSnapshot.fromJson(Map<String, dynamic> json) => OfflineAccountSnapshot(
        accountId: json['accountId'] as String,
        sequence: BigInt.parse(json['sequence'] as String),
        availableRaw: json['availableRaw'] as String,
        decimals: json['decimals'] as int,
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      );

  static String? _toRaw(String decimal, int decimals) {
    final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(decimal);
    if (m == null) return null;
    final frac = (m.group(2) ?? '').padRight(decimals, '0');
    final truncatedFrac = frac.length > decimals ? frac.substring(0, decimals) : frac;
    return '${m.group(1)}$truncatedFrac';
  }
}

/// Persists the one snapshot this device has for its own wallet.
class OfflineAccountCache {
  static const _key = 'ghoStellarOfflineAccountSnapshot';

  Future<OfflineAccountSnapshot?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    return OfflineAccountSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> write(OfflineAccountSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(snapshot.toJson()));
  }
}
