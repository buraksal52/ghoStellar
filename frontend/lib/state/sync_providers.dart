import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/env.dart';
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

/// The network the backend actually builds and submits XDR for, learned
/// from `/sync` (SERVICE.md #20). `Env.networkPassphrase` only covers the
/// brief window before the first successful sync (or a sync failure) — once
/// synced, the backend's own value always wins, so a stale or mismatched
/// build-time default can no longer make the client sign with the wrong
/// network id. `stellarSigningServiceProvider` (core_providers.dart) is
/// built from this.
final networkPassphraseProvider = Provider<String>((ref) {
  final synced = ref.watch(syncProvider).value?.networkPassphrase;
  return (synced == null || synced.isEmpty) ? Env.networkPassphrase : synced;
});

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
