import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/config/env.dart';

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
