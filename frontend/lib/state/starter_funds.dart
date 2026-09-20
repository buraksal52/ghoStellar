import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_error.dart';
import '../core/utils/amount_formatter.dart';
import '../data/stellar/horizon_read_service.dart';
import '../data/storage/starter_funds_flag.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'wallet_providers.dart';

final starterFundsProvider = Provider((ref) => StarterFunds(ref));
final starterFundsFlagProvider = Provider((ref) => StarterFundsFlag());

class StarterFundsResult {
  const StarterFundsResult({this.added});

  /// What the wallet actually gained of the app's asset, if it could be read
  /// back; null when it was already funded or nothing showed up.
  final String? added;
}

/// "Get test funds", on testnet: the faucet (friendbot) funds the account with
/// native XLM — the app's one unit — unless it already has enough. Nothing is
/// signed or submitted by the app: the balance simply appears.
///
/// (A previous version traded part of that balance for USDC on the DEX. That
/// depended on testnet order-book liquidity and could sit for a long time or
/// fail outright; the app now holds native XLM so there is nothing to trade.)
///
/// Safe to repeat: friendbot refusing an account it already funded is fine as
/// long as the account exists.
class StarterFunds {
  StarterFunds(
    this._ref, {
    this.accountRetryDelay = const Duration(seconds: 2),
    this.accountAttempts = 4,
    this.requestTimeout = const Duration(seconds: 15),
  });

  final Ref _ref;
  final Duration accountRetryDelay;
  final int accountAttempts;

  /// Upper bound for one faucet or Horizon call, so a stalled network ends in
  /// an error card instead of a spinner that never stops.
  final Duration requestTimeout;

  /// Throws [ApiException] describing the step that failed. [progress]
  /// receives a short user-facing label as each step starts.
  Future<StarterFundsResult> run({void Function(String label)? progress}) async {
    if (_ref.read(walletProvider).keyPair == null) {
      throw ApiException(code: 'auth.invalid_token', message: 'wallet is locked');
    }

    progress?.call('Preparing your wallet…');
    final before = await _readBalances() ?? AccountBalances.notFunded;
    final after = await _ensureAccount(before);
    return StarterFundsResult(added: _gained(before, after));
  }

  /// What [after] holds of the app's asset beyond [before], or null if nothing.
  String? _gained(AccountBalances before, AccountBalances after) {
    final was = BigInt.tryParse(AmountFormatter.toRaw(before.payAsset, 7) ?? '');
    final now = BigInt.tryParse(AmountFormatter.toRaw(after.payAsset, 7) ?? '');
    if (was == null || now == null || now <= was) return null;
    final padded = (now - was).toString().padLeft(8, '0');
    return '${padded.substring(0, padded.length - 7)}.${padded.substring(padded.length - 7)}';
  }

  /// Same 2 XLM floor as [AccountBalances.feeBalanceLow] (1 base reserve +
  /// one trustline's worth + a few fees), but checked directly against
  /// native regardless of the configured asset — [feeBalanceLow] itself is
  /// false whenever native IS the app's one asset, since it exists to flag a
  /// *separate, invisible* fee balance running low, which isn't the case here.
  static final BigInt _minNativeRaw = BigInt.from(20000000); // 2 XLM, 7 decimals

  bool _hasEnoughForFees(AccountBalances b) {
    if (!b.exists) return false;
    final raw = AmountFormatter.toRaw(b.native, 7);
    final value = raw == null ? null : BigInt.tryParse(raw);
    return value != null && value >= _minNativeRaw;
  }

  /// The account as it is once it can pay fees. An account that already has
  /// enough ([current]) needs no faucet call at all. Friendbot refuses an
  /// account it already funded, so "the call said no" is fine as long as the
  /// account exists; what must hold is that it does — and Horizon can take a
  /// moment to serve a brand-new one.
  Future<AccountBalances> _ensureAccount(AccountBalances current) async {
    if (_hasEnoughForFees(current)) return current;

    ApiException? fundError;
    try {
      await _ref.read(authApiProvider).fundTestnetXlm().timeout(requestTimeout);
    } on ApiException catch (e) {
      fundError = e;
    } on TimeoutException {
      fundError = ApiException(code: 'auth.fund_failed', message: 'faucet did not answer');
    }
    for (var attempt = 0; attempt < accountAttempts; attempt++) {
      final balances = await _readBalances();
      if (balances != null && balances.exists) return balances;
      if (attempt < accountAttempts - 1) await Future<void>.delayed(accountRetryDelay);
    }
    throw fundError ?? ApiException(code: 'auth.fund_failed', message: 'account not visible on chain');
  }

  /// A fresh read (never the cached one); null when Horizon can't be reached,
  /// which callers treat like "not there yet".
  Future<AccountBalances?> _readBalances() async {
    _ref.invalidate(balancesProvider);
    try {
      return await _ref.read(balancesProvider.future).timeout(requestTimeout);
    } catch (_) {
      return null;
    }
  }
}
