import 'env.dart';

/// The one asset a cheque is written in. Everything that names the asset —
/// the payment-request URI, the on-screen unit, an offline payment's
/// operation — reads it from here, so it can't drift between screens.
///
/// A native (XLM) asset has no issuer. Anything else is identified by
/// code **and** issuer, exactly as SEP-7 (`asset_code` + `asset_issuer`) and
/// Stellar itself do: two assets sharing a code are different assets.
class PayAsset {
  const PayAsset({required this.code, this.issuer});

  final String code;

  /// The issuing account (`G…`), or null for native XLM.
  final String? issuer;

  bool get isNative => issuer == null;

  /// What the UI prints next to an amount.
  String get label => code;

  /// The deployment's asset, from `--dart-define=PAY_ASSET_CODE/PAY_ASSET_ISSUER`.
  /// Set `PAY_ASSET_ISSUER=` (empty) for native XLM.
  static PayAsset get configured => PayAsset(
        code: Env.payAssetCode,
        issuer: Env.payAssetIssuer.isEmpty ? null : Env.payAssetIssuer,
      );

  @override
  bool operator ==(Object other) =>
      other is PayAsset && other.code == code && other.issuer == issuer;

  @override
  int get hashCode => Object.hash(code, issuer);

  @override
  String toString() => issuer == null ? code : '$code:$issuer';
}
