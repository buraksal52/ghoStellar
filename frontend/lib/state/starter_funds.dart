import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_error.dart';
import '../core/utils/anchor_status.dart';
import '../data/api/models/anchor_models.dart';
import '../data/api/models/sep6_models.dart';
import '../data/stellar/horizon_read_service.dart';
import '../data/storage/starter_funds_flag.dart';
import 'anchor_bookkeeping.dart';
import 'anchor_providers.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'trustline_setup.dart';

/// What the testnet "starter funds" deposit wires, in the anchor's fiat
/// currency (TRY). Inside the TR mock anchor's 50–3,000 TRY limits — the
/// client has no range check of its own, so this constant has to stay in it.
const starterDepositTry = '1000';

final starterFundsProvider = Provider((ref) => StarterFunds(ref));
final starterFundsFlagProvider = Provider((ref) => StarterFundsFlag());

class StarterFundsResult {
  const StarterFundsResult({this.usdcAdded});

  /// What the anchor actually paid out (its own rate and fee), if it said.
  final String? usdcAdded;
}

/// "Get test funds", end to end, on testnet: everything a brand-new wallet
/// needs before it can hold, send or pool USDC.
///
///  1. network fees — friendbot funds the account (XLM, never shown as an
///     amount; the app has one unit, USDC), unless it already has enough;
///  2. the USDC trustline, if it isn't open yet;
///  3. a TRY→USDC deposit through the TR mock anchor, whose sandbox endpoint
///     stands in for the bank wire. Friendbot can't hand out USDC (the issuer
///     is not ours), so this is how USDC gets into a test wallet.
///
/// Every step is skipped or harmless when already done, so a retry after a
/// partial failure just carries on.
class StarterFunds {
  StarterFunds(
    this._ref, {
    this.pollInterval = const Duration(seconds: 1),
    this.maxPolls = 60, // ~1 minute of polling; the anchor keeps going after
    this.accountRetryDelay = const Duration(seconds: 2),
    this.accountAttempts = 4,
    this.maxPollFailures = 3,
  });

  final Ref _ref;
  final Duration pollInterval;
  final int maxPolls;
  final Duration accountRetryDelay;
  final int accountAttempts;

  /// Consecutive failed polls after which the anchor is deemed unreachable.
  final int maxPollFailures;

  /// Throws [ApiException] describing the step that failed. [progress]
  /// receives a short user-facing label as each step starts;
  /// [canContinueInBackground] fires when the flow starts waiting on the bank —
  /// a wait the user may walk away from, since it finishes on its own.
  Future<StarterFundsResult> run({
    void Function(String label)? progress,
    void Function()? canContinueInBackground,
  }) async {
    void say(String label) => progress?.call(label);

    // The anchor login is independent of the wallet setup below, so it runs
    // alongside it instead of after it. Its failure is reported at the step
    // that needs it, not here.
    final anchorReady = _prepareAnchor();
    anchorReady.ignore();

    say('Preparing your wallet…');
    final balances = await _ensureAccount();

    if (!balances.hasPayAssetTrustline) {
      say('Enabling USDC…');
      await _ref.read(trustlineSetupProvider).run();
    }

    say('Requesting a deposit…');
    final anchor = await anchorReady;
    final api = _ref.read(anchorApiProvider);
    final session = _ref.read(anchorSessionProvider.notifier);
    final deposit = await session.withToken(
      anchor.id,
      (t) => api.sep6Deposit(anchor.id, t, assetCode: anchor.assetCode, amount: starterDepositTry),
    );

    say('Waiting for the bank…');
    canContinueInBackground?.call();
    await session.withToken(
      anchor.id,
      (t) => api.sep6SimulateBankTransfer(anchor.id, t, deposit.id, amount: starterDepositTry),
    );
    final tx = await _waitForTerminal(anchor.id, deposit.id, say);
    if (tx == null) {
      throw ApiException(code: 'anchor.deposit_pending', message: 'deposit not final yet');
    }
    await _ref.read(anchorBookkeepingProvider).record(
          anchorId: anchor.id,
          txId: deposit.id,
          kind: 'deposit',
          status: tx.status,
          completed: tx.isCompleted,
          assetAmount: tx.amountOut,
          stellarTxHash: tx.stellarTransactionId,
        );
    if (!tx.isCompleted) {
      throw ApiException(code: 'anchor.deposit_failed', message: tx.status);
    }
    return StarterFundsResult(usdcAdded: tx.amountOut);
  }

  /// Finds the anchor and signs in to it (SEP-10), so the token is ready by
  /// the time the deposit is requested.
  Future<AnchorInfo> _prepareAnchor() async {
    final anchor = await _anchor();
    await _ref.read(anchorSessionProvider.notifier).withToken(anchor.id, (_) async {});
    return anchor;
  }

  /// The account as it is once it can pay fees. An account that already has
  /// enough needs no friendbot call at all. Friendbot refuses an account it
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

  Future<AnchorInfo> _anchor() async {
    final anchor = _ref.read(primaryAnchorProvider) ?? (await _ref.read(anchorsProvider.future)).firstOrNull;
    if (anchor == null) {
      throw ApiException(code: 'anchor.not_allowed', message: 'anchor not loaded');
    }
    return anchor;
  }

  /// Polls until the anchor reaches a final state; null if it never does
  /// within [maxPolls] (it keeps processing — the Bank tab shows it later).
  /// A blip or two is retried; [maxPollFailures] in a row means the anchor
  /// can't be reached, which is reported instead of spinning to the end.
  Future<Sep6Transaction?> _waitForTerminal(
    String anchorId,
    String txId,
    void Function(String label) say,
  ) async {
    final api = _ref.read(anchorApiProvider);
    final session = _ref.read(anchorSessionProvider.notifier);
    var failures = 0;
    var trustlineTried = false;
    String? lastStatus;
    for (var poll = 0; poll < maxPolls; poll++) {
      Sep6Transaction? tx;
      try {
        tx = await session.withToken(anchorId, (t) => api.sep6Transaction(anchorId, t, txId));
        failures = 0;
      } catch (e) {
        if (++failures >= maxPollFailures) rethrow;
      }
      if (tx != null) {
        if (tx.isTerminal) return tx;
        if (tx.status == 'pending_trust' && !trustlineTried) {
          // The anchor is holding the payout until the trustline exists.
          trustlineTried = true;
          say('Enabling USDC…');
          await _ref.read(trustlineSetupProvider).run();
        } else if (tx.status != lastStatus && tx.status != 'pending_user_transfer_start') {
          // (Not "waiting for your transfer": the sandbox wire is already sent.)
          say(anchorStatusLabel(tx.status, isDeposit: true));
        }
        lastStatus = tx.status;
      }
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }
}
