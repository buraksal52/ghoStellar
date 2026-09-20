import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/config/env.dart';
import '../../core/config/pay_asset.dart';
import '../../core/utils/amount_formatter.dart';

/// Reads account balances directly from Horizon testnet. This is the one
/// deliberate exception to "the app only talks to the backend gateway": the
/// backend has no public balance-read endpoint (only `pay-chain-gateway`,
/// which is internal-only, talks to Horizon), and reading one's own account
/// balance client-side is standard, safe, non-custodial wallet practice —
/// it never touches a private key.
class AccountBalances {
  const AccountBalances({required this.native, required this.other, this.exists = true});

  /// Native XLM balance, decimal string (e.g. "1248.7300000").
  final String native;

  /// Non-native balances (e.g. USDC), keyed by asset code.
  final Map<String, String> other;

  final bool exists;

  /// The app deals in ONE asset ([PayAsset.configured], native XLM by default)
  /// — cheques, the pool and the bank ramp all use it. For a non-native
  /// deployment, [native] is otherwise only the network-fee balance, so
  /// screens show this getter as "the" balance.
  bool get payAssetIsNative => PayAsset.configured.isNative;

  /// Balance of the app's one asset; `'0'` when the account holds none (no
  /// trustline yet, or the account doesn't exist).
  String get payAsset => payAssetIsNative ? native : (other[PayAsset.configured.code] ?? '0');

  /// Whether the account holds any of the app's one asset. False for an
  /// account without a trustline or without an on-chain existence.
  bool get holdsPayAsset {
    final raw = AmountFormatter.toRaw(payAsset, 7);
    final value = raw == null ? null : BigInt.tryParse(raw);
    return value != null && value > BigInt.zero;
  }

  /// Whether the account has the app's asset trustline open — even with a zero
  /// balance, which Horizon still lists. Always true for native XLM.
  bool get hasPayAssetTrustline => payAssetIsNative || other.containsKey(PayAsset.configured.code);

  /// Stellar needs a little XLM on every account for fees and the reserve
  /// (1 base + 0.5 per trustline), but the app never shows XLM as an amount —
  /// only this warning when it runs low. 2 XLM leaves room for the base
  /// reserve, one trustline and a few fees. Integer math on the raw string.
  static final BigInt _minFeeBalanceRaw = BigInt.from(20000000); // 2 XLM, 7 decimals

  bool get feeBalanceLow {
    if (!exists || payAssetIsNative) return false;
    final raw = AmountFormatter.toRaw(native, 7);
    final value = raw == null ? null : BigInt.tryParse(raw);
    return value != null && value < _minFeeBalanceRaw;
  }

  static const AccountBalances notFunded =
      AccountBalances(native: '0', other: {}, exists: false);
}

class HorizonReadService {
  HorizonReadService({StellarSDK? sdk}) : _sdk = sdk ?? StellarSDK(Env.horizonUrl);

  final StellarSDK _sdk;

  Future<AccountBalances> fetchBalances(String accountId) async {
    try {
      final account = await _sdk.accounts.account(accountId);
      final other = <String, String>{};
      var native = '0';
      for (final b in account.balances) {
        if (b.assetType == Asset.TYPE_NATIVE) {
          native = b.balance;
        } else if (b.assetCode != null) {
          other[b.assetCode!] = b.balance;
        }
      }
      return AccountBalances(native: native, other: other);
    } on ErrorResponse catch (e) {
      if (e.code == 404) return AccountBalances.notFunded;
      rethrow;
    }
  }

  /// The full account record — sequence number included — for building an
  /// offline payment locally (`offline_payment_builder.dart`). `null` for an
  /// unfunded account (nothing to build a snapshot from yet).
  Future<AccountResponse?> fetchAccount(String accountId) async {
    try {
      return await _sdk.accounts.account(accountId);
    } on ErrorResponse catch (e) {
      if (e.code == 404) return null;
      rethrow;
    }
  }
}
