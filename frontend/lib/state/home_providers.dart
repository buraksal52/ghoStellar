import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/stellar/horizon_read_service.dart';
import 'core_providers.dart';
import 'wallet_providers.dart';

/// Balances read directly from Horizon testnet — independent of `/sync`, so
/// a slow/failed Horizon call never blocks cheque/pool data from rendering.
///
/// No built-in retry: Riverpod 3 would otherwise keep a failed read "loading"
/// through a long back-off, so callers awaiting it (the starter-funds flow) and
/// the Home card's own "Tap to retry" would both wait on it for a minute.
/// A successful submission can precede Horizon's updated account snapshot —
/// [balancesProvider] schedules one reconcile at [_firstReconcile] and, if
/// something is still watching then, a second at [_secondReconcile]. Two
/// shorter attempts (rather than the previous single 5s one) bracket
/// Stellar's ~5s ledger close time from both sides, so a read that lands
/// exactly on that boundary still gets a second chance instead of leaving a
/// stale balance on screen until the next manual refresh.
const _firstReconcile = Duration(seconds: 3);
const _secondReconcile = Duration(seconds: 6);

final balancesProvider = FutureProvider.autoDispose<AccountBalances>((ref) async {
  final publicKey = ref.watch(walletProvider).publicKey;
  if (publicKey == null) return AccountBalances.notFunded;
  final horizon = ref.watch(horizonReadServiceProvider);
  // Dispose cancels these timers when leaving the screen or switching
  // wallets — a build with no listener left has nothing to reconcile.
  Timer? firstTimer;
  Timer? secondTimer;
  ref.onDispose(() {
    firstTimer?.cancel();
    secondTimer?.cancel();
  });
  try {
    return await horizon.fetchBalances(publicKey);
  } finally {
    if (ref.mounted) {
      firstTimer = Timer(_firstReconcile, ref.invalidateSelf);
      secondTimer = Timer(_secondReconcile, ref.invalidateSelf);
    }
  }
}, retry: (_, _) => null);
