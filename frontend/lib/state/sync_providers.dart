import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final result = await api.sync();
    // Cached so a cold start that goes straight into offline mode
    // (`AuthGatePage`) still signs against the right network id instead of
    // silently falling back to the build-time default — see
    // [networkPassphraseProvider].
    if (result.networkPassphrase.isNotEmpty) {
      unawaited(ref.read(cachedNetworkPassphraseProvider.notifier).write(result.networkPassphrase));
    }
    return result;
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

final syncProvider = AsyncNotifierProvider<SyncNotifier, SyncResponse>(
  SyncNotifier.new,
);

const _networkPassphraseCacheKey = 'ghoStellarNetworkPassphrase';

/// The last `networkPassphrase` a successful `/sync` reported, persisted so
/// it survives a cold start that never reaches the network — see
/// [networkPassphraseProvider].
class CachedNetworkPassphraseNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_networkPassphraseCacheKey);
  }

  Future<void> write(String passphrase) async {
    state = AsyncData(passphrase);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_networkPassphraseCacheKey, passphrase);
  }
}

final cachedNetworkPassphraseProvider =
    AsyncNotifierProvider<CachedNetworkPassphraseNotifier, String?>(CachedNetworkPassphraseNotifier.new);

/// The network the backend actually builds and submits XDR for, learned
/// from `/sync` (SERVICE.md #20). Preferred order: the live `/sync` value;
/// failing that (no sync yet this session — e.g. a cold start that went
/// straight into offline mode), the last one a successful `/sync` cached to
/// disk; only a wallet that has never synced at all falls back to the
/// build-time `Env.networkPassphrase`. `stellarSigningServiceProvider`
/// (core_providers.dart) is built from this — this is what an offline
/// payment (`offline_providers.dart`) actually signs with.
final networkPassphraseProvider = Provider<String>((ref) {
  final synced = ref.watch(syncProvider).value?.networkPassphrase;
  if (synced != null && synced.isNotEmpty) return synced;
  final cached = ref.watch(cachedNetworkPassphraseProvider).value;
  if (cached != null && cached.isNotEmpty) return cached;
  return Env.networkPassphrase;
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
