import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/models/cheque_models.dart';
import 'core_providers.dart';
import 'wallet_providers.dart';

/// The single global `/sync` result — cheques, pool snapshot, trustline
/// readiness — consumed by Home/Send/Receive/Pool/Activity without
/// prop-drilling. Refreshed at startup, on pull-to-refresh, after any
/// successful `confirm-*` call, and on app resume if stale.
class SyncNotifier extends AsyncNotifier<SyncResponse> {
  @override
  Future<SyncResponse> build() => _fetch();

  Future<SyncResponse> _fetch() async {
    final api = ref.read(syncApiProvider);
    return api.sync();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

final syncProvider = AsyncNotifierProvider<SyncNotifier, SyncResponse>(
  SyncNotifier.new,
);

/// Cheques addressed to me that are awaiting my claim.
final pendingClaimsProvider = Provider<List<Cheque>>((ref) {
  final sync = ref.watch(syncProvider).value;
  final me = ref.watch(walletProvider).publicKey;
  if (sync == null || me == null) return const [];
  const claimable = {
    ChequeState.imzaliRezerve,
    ChequeState.fonlaniyor,
    ChequeState.havuzda,
  };
  return sync.cheques
      .where((c) => c.receiverAddress == me && claimable.contains(c.state))
      .toList();
});
