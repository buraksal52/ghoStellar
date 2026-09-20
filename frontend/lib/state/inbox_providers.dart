import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/handoff_inbox.dart';
import 'claim_core.dart';
import 'wallet_providers.dart';

final handoffInboxStoreProvider = Provider((ref) => HandoffInboxStore());

/// Cheque handoffs accepted while offline (or that failed to claim for some
/// other retryable reason), retried silently — no signing overlay, nothing
/// for the user to watch — until they succeed or the server says the
/// cheque itself is done for. Durable across restarts (`HandoffInboxStore`).
///
/// Retried: right after [add], every [retryInterval] while anything is
/// pending, and whenever the app comes to the foreground
/// ([AppLifecycleRetry] in `features/shared/widgets/app_shell.dart`).
class PendingHandoffsNotifier extends AsyncNotifier<List<PendingHandoff>> {
  static const retryInterval = Duration(seconds: 15);

  Timer? _timer;
  bool _retrying = false;

  @override
  Future<List<PendingHandoff>> build() async {
    // Same reasoning as `PendingOfflinePaymentsNotifier.build()`
    // (`offline_providers.dart`): this notifier's Timer must survive
    // regardless of which screen is on top, not just while something
    // happens to be watching it.
    ref.keepAlive();
    ref.onDispose(() => _timer?.cancel());
    final items = await ref.read(handoffInboxStoreProvider).readAll();
    if (items.isNotEmpty) _scheduleRetry();
    return items;
  }

  Future<void> add(PendingHandoff handoff) async {
    // Wait for build() rather than reading state.value directly: otherwise
    // a fast caller could write before the initial load resolves, and have
    // build()'s own (now stale) result clobber it right after.
    final current = await future;
    // A re-tap of the same handoff (the sender's tag/QR was offered again)
    // must not queue a second attempt.
    if (current.any((h) => h.chequeId == handoff.chequeId)) return;
    final next = [...current, handoff];
    state = AsyncData(next);
    await ref.read(handoffInboxStoreProvider).writeAll(next);
    _scheduleRetry();
    // Awaited, not fire-and-forget: a caller that just failed a live claim
    // (offline) gets one more attempt before add() returns, and by the time
    // it does, state reflects that attempt — not a race with it.
    await retryAll();
  }

  /// Tries every pending handoff once. Safe to call often — a retry already
  /// in flight is skipped, not stacked.
  Future<void> retryAll() async {
    if (_retrying) return;
    final current = await future;
    if (current.isEmpty) {
      _stopRetrying();
      return;
    }
    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) return; // Locked — nothing to sign with yet.

    _retrying = true;
    try {
      final remaining = <PendingHandoff>[];
      var changed = false;
      for (final h in current) {
        try {
          await performClaim(ref, keyPair, h.chequeId);
          changed = true; // Claimed — drop it.
        } catch (e) {
          if (classifyClaimFailure(e) == ClaimOutcome.gone) {
            changed = true; // Nothing left to try — drop it.
          } else {
            remaining.add(h); // Still offline/unreachable — keep it.
          }
        }
      }
      if (changed) {
        state = AsyncData(remaining);
        await ref.read(handoffInboxStoreProvider).writeAll(remaining);
      }
      if (remaining.isEmpty) _stopRetrying();
    } finally {
      _retrying = false;
    }
  }

  void _scheduleRetry() {
    _timer ??= Timer.periodic(retryInterval, (_) => retryAll());
  }

  void _stopRetrying() {
    _timer?.cancel();
    _timer = null;
  }
}

final pendingHandoffsProvider =
    AsyncNotifierProvider<PendingHandoffsNotifier, List<PendingHandoff>>(
  PendingHandoffsNotifier.new,
);
