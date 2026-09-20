import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/config/pay_asset.dart';
import '../../core/utils/amount_formatter.dart';

/// Builds the one transaction "Get test funds" needs: trade some of the
/// faucet's native XLM for the app's asset (USDC), opening the trustline first
/// in the same transaction when the account doesn't have it yet.
///
/// Pure and local, like `OfflinePaymentBuilder`: it returns an UNSIGNED
/// envelope; the caller signs it and `pay-tx-service` submits it.
class StarterSwapBuilder {
  const StarterSwapBuilder();

  /// Flat fee offered per operation; Stellar refunds what the ledger doesn't
  /// charge, so this is headroom against a fee surge, not the cost.
  static const feeStroops = 10000;

  /// How long the signed transaction stays valid. The quote it embeds is only
  /// good for moments, so this is short.
  static const validity = Duration(minutes: 5);

  /// The share of the quoted amount the trade must still deliver, in percent.
  /// A price that moved further than this between the quote and the ledger
  /// fails the transaction instead of settling at a bad rate.
  static const minReceivePercent = 95;

  /// [sendAmount] XLM is sold for at least [minReceivePercent] % of
  /// [quotedAmount] of [asset], paid to the account itself. [path] is the
  /// route Horizon quoted.
  String build({
    required String accountId,
    required BigInt sequence,
    required PayAsset asset,
    required String sendAmount,
    required String quotedAmount,
    required List<Asset> path,
    required bool openTrustline,
    DateTime? now,
  }) {
    final usdc = Asset.createNonNativeAsset(asset.code, asset.issuer!);
    final builder = TransactionBuilder(Account(accountId, sequence));
    if (openTrustline) {
      builder.addOperation(ChangeTrustOperationBuilder(usdc, ChangeTrustOperationBuilder.MAX_LIMIT).build());
    }
    builder.addOperation(
      PathPaymentStrictSendOperationBuilder(Asset.NATIVE, sendAmount, accountId, usdc, _minReceive(quotedAmount))
          .setPath(path)
          .build(),
    );
    final maxTime = (now ?? DateTime.now()).add(validity);
    builder
      ..addPreconditions(TransactionPreconditions()..timeBounds = TimeBounds(0, maxTime.millisecondsSinceEpoch ~/ 1000))
      ..setMaxOperationFee(feeStroops);
    return builder.build().toEnvelopeXdrBase64();
  }

  /// [minReceivePercent] of [quoted], in integer stroops (never a float) and
  /// as a plain decimal — no digit grouping, which Stellar amounts can't carry.
  static String _minReceive(String quoted) {
    final raw = BigInt.parse(AmountFormatter.toRaw(quoted, 7)!);
    final padded = (raw * BigInt.from(minReceivePercent) ~/ BigInt.from(100)).toString().padLeft(8, '0');
    return '${padded.substring(0, padded.length - 7)}.${padded.substring(padded.length - 7)}';
  }
}
