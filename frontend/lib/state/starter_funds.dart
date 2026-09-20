import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/config/pay_asset.dart';
import '../core/errors/api_error.dart';
import '../core/utils/amount_formatter.dart';
import '../data/api/models/tx_models.dart';
import '../data/stellar/horizon_read_service.dart';
import '../data/stellar/starter_swap_builder.dart';
import '../data/storage/starter_funds_flag.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'trustline_setup.dart';
import 'wallet_providers.dart';

/// How much of the faucet's balance (10,000 of the network's native coin) is
/// traded for USDC. Testnet liquidity is thin — a few hundred at most — so
/// this stays modest; it is worth about as many USDC.
const starterSwapSend = '100';

final starterFundsProvider = Provider((ref) => StarterFunds(ref));
final starterFundsFlagProvider = Provider((ref) => StarterFundsFlag());

class StarterFundsResult {
  const StarterFundsResult({this.usdcAdded});

  /// What the wallet actually gained, if it could be read back.
  final String? usdcAdded;
}

/// "Get test funds", end to end, on testnet: everything a brand-new wallet
/// needs before it can hold, send or pool USDC.
///
///  1. the faucet funds the account (friendbot — native coin, which pays network
///     fees and is never shown as an amount; the app has one unit, USDC),
///     unless it already has enough;
///  2. ONE transaction, signed once: open the USDC trustline if it isn't open
///     and trade part of that faucet balance for USDC on the Stellar DEX. The
///     user only ever sees USDC arrive.
///
/// The mock anchor (TRY↔USDC) is deliberately not involved: a fiat deposit
/// takes an anchor login, a deposit, a simulated wire and a payout, where the
/// trade is a single ledger close. The Bank tab still does TRY.
///
/// Each step is skipped or harmless when already done, so a retry after a
/// partial failure just carries on.
class StarterFunds {
  StarterFunds(
    this._ref, {
    this.accountRetryDelay = const Duration(seconds: 2),
    this.accountAttempts = 4,
  });

  final Ref _ref;
  final Duration accountRetryDelay;
  final int accountAttempts;

  /// Throws [ApiException] describing the step that failed. [progress]
  /// receives a short user-facing label as each step starts.
  Future<StarterFundsResult> run({void Function(String label)? progress}) async {
    void say(String label) => progress?.call(label);
    final keyPair = _ref.read(walletProvider).keyPair;
    if (keyPair == null) {
      throw ApiException(code: 'auth.invalid_token', message: 'wallet is locked');
    }
    final asset = PayAsset.configured;

    say('Preparing your wallet…');
    final before = await _ensureAccount();
    // A deployment whose one unit IS the native coin has nothing to trade for.
    if (asset.isNative) return const StarterFundsResult();

    say('Getting ${asset.label}…');
    final horizon = _ref.read(horizonReadServiceProvider);
    final quote = await horizon.quoteFromNative(starterSwapSend, asset);
    if (quote == null) {
      throw ApiException(code: 'starter.no_liquidity', message: 'no route for $starterSwapSend');
    }
    final sequence = await horizon.fetchSequence(keyPair.accountId);
    if (sequence == null) {
      throw ApiException(code: 'auth.fund_failed', message: 'account not visible on chain');
    }

    final openTrustline = !before.hasPayAssetTrustline;
    final xdr = const StarterSwapBuilder().build(
      accountId: keyPair.accountId,
      sequence: sequence,
      asset: asset,
      sendAmount: starterSwapSend,
      quotedAmount: quote.destinationAmount,
      path: quote.path,
      openTrustline: openTrustline,
    );
    final signed = _ref.read(stellarSigningServiceProvider).signTransactionXdr(xdr, keyPair);
    // Throws if the network rejected it (e.g. the price moved past the limit).
    await _ref.read(txApiProvider).submit(
          idempotencyKey: const Uuid().v4(),
          purpose: 'starter_swap',
          kind: TxKind.classic,
          xdr: signed,
        );

    if (openTrustline) {
      try {
        // The backend keeps its own record of the trustline (pool, bank).
        await _ref.read(trustlineSetupProvider).confirm();
      } on ApiException {
        // The USDC is in the wallet already; a failed bookkeeping call must not
        // read as a failed top-up. The Home hint offers the USDC setup again.
      }
    }

    final after = await _readBalances();
    return StarterFundsResult(usdcAdded: after == null ? quote.destinationAmount : _gained(before, after));
  }

  /// What [after] holds of the app's asset beyond [before], or null if nothing.
  String? _gained(AccountBalances before, AccountBalances after) {
    final was = BigInt.tryParse(AmountFormatter.toRaw(before.payAsset, 7) ?? '');
    final now = BigInt.tryParse(AmountFormatter.toRaw(after.payAsset, 7) ?? '');
    if (was == null || now == null || now <= was) return null;
    final padded = (now - was).toString().padLeft(8, '0');
    return '${padded.substring(0, padded.length - 7)}.${padded.substring(padded.length - 7)}';
  }

  /// The account as it is once it can pay fees. An account that already has
  /// enough needs no faucet call at all. Friendbot refuses an account it
  /// already funded, so "the call said no" is fine as long as the account
  /// exists; what must hold is that it does — and Horizon can take a moment to
  /// serve a brand-new one.
  Future<AccountBalances> _ensureAccount() async {
    final current = await _readBalances();
    if (current != null && current.exists && !current.feeBalanceLow) return current;

    ApiException? fundError;
    try {
      await _ref.read(authApiProvider).fundTestnetXlm();
    } on ApiException catch (e) {
      fundError = e;
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
      return await _ref.read(balancesProvider.future);
    } catch (_) {
      return null;
    }
  }
}
