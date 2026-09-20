import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/config/pay_asset.dart';
import 'offline_account_cache.dart';

/// Builds and signs the classic Stellar payment the sender-is-offline path
/// hands to the receiver — see `core/payments/payment_uri.dart`'s
/// [OfflinePayment] doc for why this exists and what it does not give you
/// (no escrow, no recall).
///
/// Everything here is pure/local: no network call, so it works with the
/// device's radio off. Its correctness end to end is checked by
/// `offline_payment_verifier.dart` reconstructing every one of these
/// decisions from the signed XDR alone.
class OfflinePaymentBuilder {
  const OfflinePaymentBuilder();

  /// Flat fee offered per operation (there is exactly one). Stellar refunds
  /// the difference between this and the ledger's actual base fee — this is
  /// generous headroom, not what gets charged.
  static const feeStroops = 10000;

  /// How long the payment can still be submitted. Deliberately generous —
  /// this is exactly how long an offline receiver's inbox may need to wait
  /// for a connection, not a short anti-replay window.
  static const validity = Duration(hours: 24);

  /// Builds a payment of [amount] (a plain decimal string of [asset]) from
  /// [snapshot]'s account/sequence to [destination], memoed with the hash of
  /// [nonce] so the receiver can tie it to the request it issued, and signs
  /// it with [sender]. Returns the signed envelope, base64.
  String buildAndSign({
    required KeyPair sender,
    required OfflineAccountSnapshot snapshot,
    required String destination,
    required String amount,
    required String nonce,
    required PayAsset asset,
    required String networkPassphrase,
    DateTime? now,
  }) {
    final account = Account(snapshot.accountId, snapshot.sequence);
    final sdkAsset = asset.isNative ? Asset.NATIVE : Asset.createNonNativeAsset(asset.code, asset.issuer!);
    final op = PaymentOperationBuilder(destination, sdkAsset, amount).build();

    final maxTime = (now ?? DateTime.now()).add(validity);
    final preconditions = TransactionPreconditions()
      ..timeBounds = TimeBounds(0, maxTime.millisecondsSinceEpoch ~/ 1000);

    final tx = (TransactionBuilder(account)
          ..addOperation(op)
          ..addMemo(MemoHash(Uint8List.fromList(sha256.convert(utf8.encode(nonce)).bytes)))
          ..addPreconditions(preconditions)
          ..setMaxOperationFee(feeStroops))
        .build();
    tx.sign(sender, Network(networkPassphrase));
    return tx.toEnvelopeXdrBase64();
  }
}
