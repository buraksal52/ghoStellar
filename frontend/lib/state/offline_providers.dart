import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../core/config/pay_asset.dart';
import '../core/errors/api_error.dart';
import '../data/api/models/tx_models.dart';
import '../data/storage/offline_payment_store.dart';
import '../data/stellar/offline_account_cache.dart';
import 'core_providers.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

/// Classic Stellar amounts are always 7-decimal fixed point, for every
/// asset, native or issued — unlike a Soroban token contract's amounts
/// (which is what `Cheque.decimals` reports), this is a network constant,
/// not something a `/sync` response carries.
const classicStellarDecimals = 7;

final offlineAccountCacheProvider = Provider((ref) => OfflineAccountCache());
final offlinePaymentStoreProvider = Provider((ref) => OfflinePaymentStore());

/// The wallet's own cached balance + sequence number, refreshed whenever the
/// app is online (`AppShell`) and consumed by `SendPage`'s offline fallback
/// to build a payment without a network call. See `OfflineAccountSnapshot`.
class AccountSnapshotNotifier extends AsyncNotifier<OfflineAccountSnapshot?> {
  @override
  Future<OfflineAccountSnapshot?> build() => ref.read(offlineAccountCacheProvider).read();

  /// Fetches the live balance/sequence from Horizon and caches it. Silently
  /// keeps the old snapshot on failure (typically: no connection right now,
  /// which is exactly when the cached value matters most).
  Future<void> refresh() async {
    final me = ref.read(walletProvider).publicKey;
    if (me == null) return;
    try {
      final account = await ref.read(horizonReadServiceProvider).fetchAccount(me);
      if (account == null) return; // Unfunded, or the asset's trustline isn't set up — nothing to cache.
      final snapshot = OfflineAccountSnapshot.fromAccount(account, PayAsset.configured, classicStellarDecimals);
      if (snapshot == null) return;
      state = AsyncData(snapshot);
      await ref.read(offlineAccountCacheProvider).write(snapshot);
    } catch (_) {
      // Offline / Horizon down — the cached snapshot is what we have.
    }
  }

  /// Consumes [amountRaw] and advances the sequence, so a second offline
  /// payment built before either reaches the network isn't built against
  /// the same funds or the same sequence number as the first.
  Future<void> reserve(String amountRaw) async {
    final current = await future;
    if (current == null) return;
    final next = current.reserve(amountRaw);
    state = AsyncData(next);
    await ref.read(offlineAccountCacheProvider).write(next);
  }
}

final accountSnapshotProvider =
    AsyncNotifierProvider<AccountSnapshotNotifier, OfflineAccountSnapshot?>(AccountSnapshotNotifier.new);

/// Payment-request ids this device has already answered with a *classic*
/// offline payment (never a cheque, so `paidRequestIdsProvider`'s `/sync`
/// read can never see it). In memory, hydrated from disk once at startup
/// (`AppShell`) — a courtesy pre-check, same as `paidRequestIdsProvider`;
/// the actual guarantee against replay is the payment's own memo/nonce
/// pairing, checked by `OfflinePaymentVerifier` on the receiving end.
class OfflineSpentRequestIdsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void hydrate(Set<String> ids) => state = {...state, ...ids};

  void add(String id) => state = {...state, id};
}

final offlineSpentRequestIdsProvider =
    NotifierProvider<OfflineSpentRequestIdsNotifier, Set<String>>(OfflineSpentRequestIdsNotifier.new);

/// A verified offline payment waiting for a `POST /tx/submit`, retried
/// silently — same shape as `PendingHandoffsNotifier`, for the same reason
/// (durable across restarts, no signing overlay for a background retry).
///
/// The idempotency key is the *transaction's own hash*: whichever side (the
/// receiver who verified it, or the sender who built it) gets online first
/// submits it, and the other side's later attempt comes back `replayed`
/// instead of double-submitting — `pay-tx-service`'s own idempotency table
/// makes that safe (`backend/services/tx`).
class PendingOfflinePaymentsNotifier extends AsyncNotifier<List<PendingOfflinePayment>> {
  static const retryInterval = Duration(seconds: 15);

  Timer? _timer;
  bool _retrying = false;

  @override
  Future<List<PendingOfflinePayment>> build() async {
    ref.onDispose(() => _timer?.cancel());
    final items = await ref.read(offlinePaymentStoreProvider).readQueue();
    if (items.isNotEmpty) _scheduleRetry();
    return items;
  }

  Future<void> add(PendingOfflinePayment payment) async {
    final current = await future;
    if (current.any((p) => p.nonce == payment.nonce)) return;
    final next = [...current, payment];
    state = AsyncData(next);
    await ref.read(offlinePaymentStoreProvider).writeQueue(next);
    _scheduleRetry();
    await retryAll(); // one immediate attempt, same as the handoff inbox.
  }

  Future<void> retryAll() async {
    if (_retrying) return;
    final current = await future;
    if (current.isEmpty) {
      _stopRetrying();
      return;
    }

    _retrying = true;
    try {
      final remaining = <PendingOfflinePayment>[];
      var changed = false;
      for (final p in current) {
        try {
          await _submit(p);
          changed = true; // Reached the network (or was already there) — drop it.
        } on ApiException catch (e) {
          if (_terminalSubmitCodes.contains(e.code)) {
            changed = true; // Can never succeed — drop it.
          } else {
            remaining.add(p); // Still offline/unreachable — keep it.
          }
        } catch (_) {
          remaining.add(p);
        }
      }
      if (changed) {
        state = AsyncData(remaining);
        await ref.read(offlinePaymentStoreProvider).writeQueue(remaining);
      }
      if (remaining.isEmpty) _stopRetrying();
    } finally {
      _retrying = false;
    }
  }

  Future<void> _submit(PendingOfflinePayment p) async {
    final networkPassphrase = ref.read(networkPassphraseProvider);
    final hash = AbstractTransaction.fromEnvelopeXdrString(p.signedXdr).hash(Network(networkPassphrase));
    await ref.read(txApiProvider).submit(
          idempotencyKey: 'offline-${_hex(hash)}',
          purpose: 'offline_payment',
          kind: TxKind.classic,
          xdr: p.signedXdr,
        );
  }

  void _scheduleRetry() {
    _timer ??= Timer.periodic(retryInterval, (_) => retryAll());
  }

  void _stopRetrying() {
    _timer?.cancel();
    _timer = null;
  }
}

const _terminalSubmitCodes = {
  'tx.bad_request',
};

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

final pendingOfflinePaymentsProvider =
    AsyncNotifierProvider<PendingOfflinePaymentsNotifier, List<PendingOfflinePayment>>(
  PendingOfflinePaymentsNotifier.new,
);
