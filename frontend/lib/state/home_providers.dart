import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/stellar/horizon_read_service.dart';
import 'core_providers.dart';
import 'wallet_providers.dart';

/// Balances read directly from Horizon testnet — independent of `/sync`, so
/// a slow/failed Horizon call never blocks cheque/pool data from rendering.
final balancesProvider = FutureProvider<AccountBalances>((ref) async {
  final publicKey = ref.watch(walletProvider).publicKey;
  if (publicKey == null) return AccountBalances.notFunded;
  final horizon = ref.watch(horizonReadServiceProvider);
  return horizon.fetchBalances(publicKey);
});
