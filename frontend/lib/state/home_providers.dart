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
final balancesProvider = FutureProvider.autoDispose<AccountBalances>((ref) async {
  final publicKey = ref.watch(walletProvider).publicKey;
  if (publicKey == null) return AccountBalances.notFunded;
  final horizon = ref.watch(horizonReadServiceProvider);
  // A successful submission can precede Horizon's updated account snapshot.
  // Keep reconciling while the balance is observed instead of caching that
  // first, possibly stale, response until the next manual refresh. Schedule
  // after completion so slow reads never overlap. Dispose cancels the timer
  // when leaving the screen or switching wallets.
  Timer? refreshTimer;
  ref.onDispose(() => refreshTimer?.cancel());
  try {
    return await horizon.fetchBalances(publicKey);
  } finally {
    if (ref.mounted) {
      refreshTimer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
    }
  }
}, retry: (_, _) => null);
