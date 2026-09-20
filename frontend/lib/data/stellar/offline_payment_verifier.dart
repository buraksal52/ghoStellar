import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/config/pay_asset.dart';

/// Why an [OfflinePaymentVerifier] call refused a payment — lets the UI say
/// something more useful than "invalid".
enum OfflineVerifyFailure {
  malformedXdr,
  notASingleClassicPayment,
  wrongDestination,
  wrongAsset,
  amountTooLow,
  memoDoesNotMatchRequest,
  noTimeLimit,
  expired,
  expiresTooFarInTheFuture,
  senderDidNotSignIt,
}

class OfflineVerifyResult {
  const OfflineVerifyResult._({this.failure, this.from, this.amount, this.decimals});

  const OfflineVerifyResult.ok({required String from, required String amount, required int decimals})
      : this._(from: from, amount: amount, decimals: decimals);

  const OfflineVerifyResult.rejected(OfflineVerifyFailure failure) : this._(failure: failure);

  final OfflineVerifyFailure? failure;

  /// Below only meaningful when [failure] is null.
  final String? from;
  final String? amount;
  final int? decimals;

  bool get isValid => failure == null;
}

/// Checks a signed offline payment the *hard* way: everything is
/// reconstructed from [OfflinePayment.signedXdr] itself — nothing from the
/// URI's own `from`/`amount` fields is trusted (those are display hints a
/// forged payload could lie about). No network call; this is exactly what
/// lets the receiver accept the payment while offline.
///
/// This is a client-side courtesy, not the source of truth (D6): the actual
/// enforcement is Horizon rejecting a bad signature or an unfunded sender
/// when the transaction is eventually submitted. What this buys the
/// receiver is knowing *now*, before waiting on a connection, whether the
/// payment is even worth keeping.
class OfflinePaymentVerifier {
  const OfflinePaymentVerifier({
    this.maxFutureExpiry = const Duration(days: 2),
  });

  /// Refuses a payment whose time limit is further out than this — a huge
  /// value here is more likely a clock/attack anomaly than a real payment
  /// (the builder's own window is 24h; this leaves headroom without being
  /// unbounded).
  final Duration maxFutureExpiry;

  /// [expectedDestination] is always *this device's own* address — a
  /// verifier never checks against anything the payload itself supplied.
  /// [minAmountRaw] is the requested amount in raw units, or null when the
  /// receiver's request left the amount open (any positive amount is fine).
  OfflineVerifyResult verify({
    required String signedXdr,
    required String expectedDestination,
    required String requestNonce,
    required PayAsset asset,
    required int decimals,
    String? minAmountRaw,
    required String networkPassphrase,
    DateTime? now,
  }) {
    final Transaction tx;
    try {
      final parsed = AbstractTransaction.fromEnvelopeXdrString(signedXdr);
      if (parsed is! Transaction) return const OfflineVerifyResult.rejected(OfflineVerifyFailure.malformedXdr);
      tx = parsed;
    } catch (_) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.malformedXdr);
    }

    if (tx.operations.length != 1) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.notASingleClassicPayment);
    }
    final op = tx.operations.single;
    if (op is! PaymentOperation) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.notASingleClassicPayment);
    }

    if (op.destination.accountId != expectedDestination) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.wrongDestination);
    }

    final opAsset = op.asset;
    final assetMatches = asset.isNative
        ? opAsset is AssetTypeNative
        : opAsset is AssetTypeCreditAlphaNum && opAsset.code == asset.code && opAsset.issuerId == asset.issuer;
    if (!assetMatches) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.wrongAsset);
    }

    final amountRaw = _toRaw(op.amount, decimals);
    if (amountRaw == null || BigInt.parse(amountRaw) <= BigInt.zero) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.amountTooLow);
    }
    if (minAmountRaw != null && BigInt.parse(amountRaw) < BigInt.parse(minAmountRaw)) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.amountTooLow);
    }

    final memo = tx.memo;
    final expectedHash = Uint8List.fromList(sha256.convert(utf8.encode(requestNonce)).bytes);
    if (memo is! MemoHash || !_bytesEqual(memo.bytes, expectedHash)) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.memoDoesNotMatchRequest);
    }

    final timeBounds = tx.preconditions?.timeBounds;
    if (timeBounds == null || timeBounds.maxTime == 0) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.noTimeLimit);
    }
    final nowTime = now ?? DateTime.now();
    final maxTime = DateTime.fromMillisecondsSinceEpoch(timeBounds.maxTime * 1000, isUtc: true);
    if (!nowTime.isBefore(maxTime)) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.expired);
    }
    if (maxTime.isAfter(nowTime.add(maxFutureExpiry))) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.expiresTooFarInTheFuture);
    }

    final sourceAccount = tx.sourceAccount.accountId;
    final signedByClaimedSender = _verifiedBy(tx, sourceAccount, networkPassphrase);
    if (!signedByClaimedSender) {
      return const OfflineVerifyResult.rejected(OfflineVerifyFailure.senderDidNotSignIt);
    }

    return OfflineVerifyResult.ok(from: sourceAccount, amount: amountRaw, decimals: decimals);
  }

  bool _verifiedBy(Transaction tx, String accountId, String networkPassphrase) {
    final KeyPair signer;
    try {
      signer = KeyPair.fromAccountId(accountId);
    } catch (_) {
      return false;
    }
    final hash = tx.hash(Network(networkPassphrase));
    for (final sig in tx.signatures) {
      try {
        if (signer.verify(hash, sig.signature.signature)) return true;
      } catch (_) {
        // A malformed signature is not a match — keep checking the rest.
      }
    }
    return false;
  }

  static String? _toRaw(String decimal, int decimals) {
    final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(decimal);
    if (m == null) return null;
    final frac = (m.group(2) ?? '').padRight(decimals, '0');
    if (frac.length > decimals) return null; // more precision than the asset has — refuse rather than truncate.
    return '${m.group(1)}$frac';
  }

  static bool _bytesEqual(Uint8List? a, Uint8List b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
