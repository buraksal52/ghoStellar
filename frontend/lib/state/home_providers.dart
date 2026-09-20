import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/stellar/horizon_read_service.dart';
import 'core_providers.dart';
import 'wallet_providers.dart';

/// Balances read directly from Horizon testnet — independent of `/sync`, so
/// a slow/failed Horizon call never blocks cheque/pool data from rendering.
///
/// No automatic retry: Riverpod 3 would otherwise keep a failed read "loading"
/// through a long back-off, so callers awaiting it (the starter-funds flow) and
/// the Home card's own "Tap to retry" would both wait on it for a minute.
final balancesProvider = FutureProvider<AccountBalances>((ref) async {
  final publicKey = ref.watch(walletProvider).publicKey;
  if (publicKey == null) return AccountBalances.notFunded;
  final horizon = ref.watch(horizonReadServiceProvider);
  return horizon.fetchBalances(publicKey);
}, retry: (_, _) => null);
