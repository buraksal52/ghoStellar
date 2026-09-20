import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_error.dart';
import '../data/api/models/anchor_models.dart';
import '../data/api/models/sep6_models.dart';
import '../data/storage/starter_funds_flag.dart';
import 'anchor_bookkeeping.dart';
import 'anchor_providers.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'sync_providers.dart';
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
///     amount; the app has one unit, USDC);
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
    this.pollInterval = const Duration(seconds: 3),
    this.maxPolls = 40, // ~2 minutes, like the Bank screen
    this.accountRetryDelay = const Duration(seconds: 2),
    this.accountAttempts = 4,
  });

  final Ref _ref;
  final Duration pollInterval;
  final int maxPolls;
  final Duration accountRetryDelay;
  final int accountAttempts;

  /// Throws [ApiException] describing the step that failed. [progress]
  /// receives a short user-facing label as each step starts.
  Future<StarterFundsResult> run({void Function(String label)? progress}) async {
    void say(String label) => progress?.call(label);

    say('Preparing your wallet…');
    await _fundAccount();

    await _ref.read(syncProvider.notifier).refresh();
    if (_ref.read(syncProvider).value?.trustlineReady != true) {
      say('Enabling USDC…');
      await _ref.read(trustlineSetupProvider).run();
    }

    say('Requesting a deposit…');
    final anchor = await _anchor();
    final api = _ref.read(anchorApiProvider);
    final session = _ref.read(anchorSessionProvider.notifier);
    final deposit = await session.withToken(
      anchor.id,
      (t) => api.sep6Deposit(anchor.id, t, assetCode: anchor.assetCode, amount: starterDepositTry),
    );

    say('Waiting for the bank…');
    await session.withToken(
      anchor.id,
      (t) => api.sep6SimulateBankTransfer(anchor.id, t, deposit.id, amount: starterDepositTry),
    );
    final tx = await _waitForTerminal(anchor.id, deposit.id);
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

  /// Friendbot refuses an account it already funded, so "the call said no" is
  /// fine as long as the account exists; what must hold is that it does — and
  /// Horizon can take a moment to serve a brand-new one.
  Future<void> _fundAccount() async {
    ApiException? fundError;
    try {
      await _ref.read(authApiProvider).fundTestnetXlm();
    } on ApiException catch (e) {
      fundError = e;
    }
    for (var attempt = 0; attempt < accountAttempts; attempt++) {
      _ref.invalidate(balancesProvider);
      try {
        if ((await _ref.read(balancesProvider.future)).exists) return;
      } catch (_) {
        // A failed read is retried like a "not found" one.
      }
      if (attempt < accountAttempts - 1) await Future<void>.delayed(accountRetryDelay);
    }
    throw fundError ?? ApiException(code: 'auth.fund_failed', message: 'account not visible on chain');
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
  Future<Sep6Transaction?> _waitForTerminal(String anchorId, String txId) async {
    final api = _ref.read(anchorApiProvider);
    final session = _ref.read(anchorSessionProvider.notifier);
    for (var poll = 0; poll < maxPolls; poll++) {
      try {
        final tx = await session.withToken(anchorId, (t) => api.sep6Transaction(anchorId, t, txId));
        if (tx.isTerminal) return tx;
      } catch (_) {
        // Transient (network, anchor hiccup): the next poll retries.
      }
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }
}
