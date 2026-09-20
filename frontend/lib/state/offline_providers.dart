import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../core/config/pay_asset.dart';
import '../core/errors/api_error.dart';
import '../core/errors/error_copy.dart';
import '../data/api/models/tx_models.dart';
import '../data/storage/offline_payment_store.dart';
import '../data/stellar/offline_account_cache.dart';
import '../data/stellar/offline_payment_builder.dart';
import '../data/stellar/offline_payment_verifier.dart';
import 'auth_providers.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

/// Classic Stellar amounts are always 7-decimal fixed point, for every
/// asset, native or issued — unlike a Soroban token contract's amounts
/// (which is what `Cheque.decimals` reports), this is a network constant,
/// not something a `/sync` response carries.
const classicStellarDecimals = 7;

final offlineAccountCacheProvider = Provider((ref) => OfflineAccountCache());
final offlinePaymentStoreProvider = Provider((ref) => OfflinePaymentStore());

/// Thin decorator around `TxApi.submit` — used by every call site that can
/// advance this wallet's own sequence number (cheque lock, pool, claim,
/// trustline, anchor withdraw, and this file's own `_submit`), so the
/// cached [accountSnapshotProvider] never drifts behind the chain within a
/// single foreground session. `POST /tx/submit` is, per architecture.md §4,
/// the only way this app ever moves anything on chain — so it's the one
/// funnel that can't be forgotten the way a 9th call site forgetting a
/// paired `refresh()` call could be. This is what an *offline* payment,
/// signed later against a snapshot that had silently gone stale, used to
/// die to (`tx_bad_seq`, permanently dropped) — see `_recoverFromBadSeq`'s
/// doc comment for the rest of that fix.
///
/// Lives here rather than in `core_providers.dart` (where `TxApi` and every
/// other API wrapper live) because it depends on `accountSnapshotProvider`,
/// defined below — putting it in `core_providers.dart` would make that file
/// import this one, which this file already imports the other way around.
/// `TxApi` itself stays a plain, `ref`-free data-layer class so `FakeTxApi`
/// overrides in tests keep working unmodified.
class ChainSubmitter {
  ChainSubmitter(this._ref);
  final Ref _ref;

  Future<SubmitResponse> submit({
    required String idempotencyKey,
    required String purpose,
    required TxKind kind,
    required String xdr,
  }) async {
    // Marked stale *before* the refresh below runs, so a refresh that fails
    // (or this whole call gets cancelled/the process dies mid-flight) never
    // leaves `ensureFresh` trusting an unconfirmed snapshot — only a refresh
    // that actually succeeds clears it.
    //
    // Awaited, not fire-and-forget: a submit reaching the network is exactly
    // the moment worth paying one extra Horizon round trip for, and doing it
    // in the background instead would leave every caller racing an
    // in-flight snapshot update with no way to know when it's done — which
    // is what let this go untested (and unnoticed) the first time.
    Future<void> refreshSnapshot() {
      _ref.read(accountSnapshotProvider.notifier).markStale();
      return _ref.read(accountSnapshotProvider.notifier).refresh();
    }

    try {
      final resp = await _ref.read(txApiProvider).submit(
            idempotencyKey: idempotencyKey,
            purpose: purpose,
            kind: kind,
            xdr: xdr,
          );
      await refreshSnapshot(); // A successful submit is the clearest signal this account's sequence just moved.
      return resp;
    } on ApiException catch (e) {
      if (e.code == 'tx.submit_failed') {
        // Reached the network and got a real verdict — even a rejected
        // transaction means we're online and this account's state might
        // have changed since the cached snapshot was taken (e.g. another
        // device's transaction landed in between).
        await refreshSnapshot();
      }
      rethrow;
    }
  }
}

final chainSubmitProvider = Provider((ref) => ChainSubmitter(ref));

/// The wallet's own cached balance + sequence number, refreshed whenever the
/// app is online (`AppShell`) and consumed by `SendPage`'s offline fallback
/// to build a payment without a network call. See `OfflineAccountSnapshot`.
class AccountSnapshotNotifier extends AsyncNotifier<OfflineAccountSnapshot?> {
  /// Set by [markStale] whenever something might have moved this account's
  /// sequence on chain without this notifier's knowledge yet — cleared only
  /// by a *successful* [refresh]. [ensureFresh] uses this so a background
  /// refresh that silently failed (still offline) doesn't get mistaken for
  /// "we checked and it's fine".
  bool _stale = false;

  @override
  Future<OfflineAccountSnapshot?> build() {
    ref.keepAlive();
    return ref.read(offlineAccountCacheProvider).read();
  }

  /// Marks the cached snapshot as untrustworthy without touching the
  /// network. Called right before/after anything that could have advanced
  /// this wallet's own sequence — see `chainSubmitProvider`, the one funnel
  /// every submit goes through.
  void markStale() => _stale = true;

  /// Fetches the live balance/sequence from Horizon and caches it. Silently
  /// keeps the old snapshot on failure (typically: no connection right now,
  /// which is exactly when the cached value matters most) — [_stale] is
  /// left set in that case, so a later [ensureFresh] knows to try again
  /// instead of trusting a snapshot that was never actually confirmed.
  Future<void> refresh() async {
    final me = ref.read(walletProvider).publicKey;
    if (me == null) return;
    // Let the initial build (the disk-cache read) settle first. Without
    // this, a `refresh()` called before that finishes races it: the
    // snapshot this method fetches and assigns to `state` below can get
    // silently clobbered back to whatever the (slower-to-settle, usually —
    // but not always, e.g. right after a fast fake in a test) `build()`
    // future resolves to, once it finally does. `reserve()` below already
    // guards against the same race the same way.
    await future;
    try {
      final account = await ref.read(horizonReadServiceProvider).fetchAccount(me);
      if (account == null) return; // Unfunded, or the asset's trustline isn't set up — nothing to cache.
      final snapshot = OfflineAccountSnapshot.fromAccount(account, PayAsset.configured, classicStellarDecimals);
      if (snapshot == null) return;
      state = AsyncData(snapshot);
      await ref.read(offlineAccountCacheProvider).write(snapshot);
      _stale = false;
    } catch (_) {
      // Offline / Horizon down — the cached snapshot is what we have.
    }
  }

  /// The cached snapshot, refreshed first only if it might be wrong: marked
  /// [markStale] since its last successful refresh, or older than [maxAge].
  /// Used right before signing an offline payment (`send_page.dart`) — a
  /// bounded, best-effort attempt via [timeout], never a hard requirement.
  /// A failed or slow refresh just falls back to whatever is cached, same
  /// as [refresh] always has; this only adds a chance to catch a drift
  /// [refresh]'s usual triggers (app resume, `chainSubmitProvider`) missed,
  /// without costing a network round trip on the common already-fresh path.
  Future<OfflineAccountSnapshot?> ensureFresh({required Duration maxAge, required Duration timeout}) async {
    final current = await future;
    final now = ref.read(clockProvider)();
    final needsRefresh = _stale || current == null || now.difference(current.fetchedAt) > maxAge;
    if (needsRefresh) {
      try {
        await refresh().timeout(timeout);
      } catch (_) {
        // Timed out, or refresh() itself threw (it shouldn't) — the cache
        // below is still whatever we had, which is the correct fallback.
      }
    }
    return future;
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

/// The last failure `PendingOfflinePaymentsNotifier.retryAll` hit, or the
/// count of items it just permanently dropped — surfaced in the UI instead
/// of failing silently (every earlier catch block here used to just `catch
/// (_)`/re-queue with no trace). `null` once a round finishes clean.
class OfflineQueueErrorNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;
}

final offlineQueueErrorProvider = NotifierProvider<OfflineQueueErrorNotifier, String?>(OfflineQueueErrorNotifier.new);

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
    // This notifier's whole point is a background retry loop that keeps
    // running regardless of which screen is on top — Riverpod 3 defaults
    // every provider to auto-dispose, which would tear down (and cancel
    // the Timer of) this one the moment its last watcher (only
    // `home_page.dart`) unmounts, silently stopping retries on Send/
    // Receive/Pool/Settings.
    ref.keepAlive();
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
      var settledAny = false;
      var reauthTried = false;
      String? lastError;
      for (final p in current) {
        if (_isExpired(p)) {
          // The builder's own TimeBounds (24h) has passed — Horizon will
          // reject this with tx_too_late forever now; retrying it is
          // pointless and would just poison the item's idempotency key.
          changed = true;
          lastError = 'An offline payment expired before it reached the network.';
          continue;
        }
        try {
          await _submit(p);
          changed = true; // Reached the network (or was already there) — drop it.
          settledAny = true;
        } on ApiException catch (e) {
          if (e.code == 'auth.invalid_token' && !reauthTried) {
            // Back online but the session is gone (an offline cold start
            // never had one, or a failed refresh cleared it): sign in again
            // once and retry this item, instead of 401-ing every 15s forever.
            reauthTried = true;
            try {
              await ref.read(authProvider.notifier).ensureSession();
              await _submit(p);
              changed = true;
              settledAny = true;
            } catch (_) {
              remaining.add(p);
              lastError = ErrorCopy.forCode('auth.invalid_token');
            }
          } else if (_terminalSubmitCodes.contains(e.code)) {
            changed = true; // Can never succeed — drop it.
            lastError = ErrorCopy.forException(e);
          } else if (e.code == 'tx.submit_failed' && e.message == 'tx_too_late') {
            // The network's own clock agrees (or caught an edge case
            // _isExpired's local estimate missed on) — the fixed TimeBounds
            // baked into the signature has passed. Never recoverable.
            changed = true;
            lastError = _expiredEnvelopeMessage(p);
          } else if (e.code == 'tx.submit_failed' && e.message == 'tx_bad_seq') {
            final outcome = await _recoverFromBadSeq(p);
            switch (outcome) {
              case _ResignedPayment(:final payment):
                changed = true;
                remaining.add(payment);
                lastError = null;
              case _BadSeqDead():
                changed = true;
                lastError = _expiredEnvelopeMessage(p);
              case _BadSeqStillWaiting():
                remaining.add(p);
                // Surfaced even though this attempt keeps retrying: a
                // silent "waiting" banner that never explains why looked
                // like a permanent hang (SERVICE.md #23's report) even
                // when it was still legitimately trying.
                lastError =
                    'Waiting for another pending payment on this account to reach the network before this one can be sent.';
            }
          } else {
            remaining.add(p); // Still offline/unreachable — keep it.
            // Surfaced even though this attempt keeps retrying: a silent
            // "waiting" banner that never explains why looked exactly like
            // a permanent hang (SERVICE.md #23's report) even when it was
            // still legitimately trying.
            lastError = ErrorCopy.forException(e);
          }
        } catch (e) {
          remaining.add(p);
          lastError = 'Could not reach the network to send a pending offline payment.';
        }
      }
      if (changed) {
        state = AsyncData(remaining);
        await ref.read(offlinePaymentStoreProvider).writeQueue(remaining);
      }
      ref.read(offlineQueueErrorProvider.notifier).set(lastError);
      if (settledAny) {
        // A queued payment just reached the network: the balances (and the
        // cheque/pool snapshot) on screen are now stale, and nothing else
        // would tell the UI — the banner just disappears.
        ref.invalidate(balancesProvider);
        unawaited(ref.read(syncProvider.notifier).refresh());
      }
      if (remaining.isEmpty) _stopRetrying();
    } finally {
      _retrying = false;
    }
  }

  bool _isExpired(PendingOfflinePayment p) =>
      ref.read(clockProvider)().isAfter(p.receivedAt.add(OfflinePaymentBuilder.validity));

  /// Maximum times a single item is re-signed against a fresh sequence
  /// before giving up — guards against a resign/fail loop (e.g. this
  /// device's own snapshot somehow never catching up with the chain).
  static const _maxResignAttempts = 3;

  /// Handles a `tx_bad_seq` rejection for [p]. The sequence number is baked
  /// into the signature at build time, so *this exact envelope* is dead —
  /// but that does NOT mean the payment itself is unrecoverable the way
  /// `tx_too_late` is: see the three outcomes below.
  ///
  /// This is SERVICE.md #23's root-cause fix, not just its symptom: an
  /// offline payment used to die here permanently the moment the cached
  /// [AccountSnapshotNotifier] snapshot it was signed against went stale —
  /// which routinely happened after an ordinary online transaction, since
  /// nothing refreshed it mid-session before `chainSubmitProvider` existed.
  Future<_BadSeqOutcome> _recoverFromBadSeq(PendingOfflinePayment p) async {
    // Only the sender can re-sign — the receiver holds no private key for
    // this account, so on their device this envelope really is the only
    // copy and it really is dead.
    // `walletProvider.publicKey` is null while locked, even for this
    // device's own wallet — so it alone can't tell "this is a receiver's
    // copy" (genuinely dead) apart from "this is ours, just not unlocked
    // right now" (should keep waiting). `SecureWalletStore.readPublicKey`
    // answers that without needing the private key: it's the address this
    // device saved at wallet creation, present whether or not the wallet is
    // currently unlocked (`secure_wallet_store.dart`).
    final storedAddress = await ref.read(secureWalletStoreProvider).readPublicKey();
    if (p.from != storedAddress) {
      // Not this device's own wallet at all — a receiver's copy of someone
      // else's payment. No key to re-sign with, ever.
      return const _BadSeqDead();
    }
    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) {
      // Ours, but the wallet isn't unlocked right now — nothing silent can
      // be done; the person has to open the app (`PendingOfflinePaymentsBanner`'s
      // "Resend" covers the case where that alone doesn't trigger a retry).
      return const _BadSeqStillWaiting();
    }
    if (p.resignAttempts >= _maxResignAttempts) {
      return const _BadSeqDead();
    }

    await ref.read(accountSnapshotProvider.notifier).refresh();
    final snapshot = await ref.read(accountSnapshotProvider.future);
    final envelope = OfflinePaymentVerifier.describe(p.signedXdr);
    if (snapshot == null || envelope == null) {
      // No fresh sequence to re-sign against right now (still offline), or
      // this device's own envelope somehow doesn't parse — either way,
      // nothing safe to do but wait for the next retry.
      return const _BadSeqStillWaiting();
    }

    // Only a genuinely stale envelope (signed against a sequence the chain
    // has already moved past) is safe to re-sign. One signed AHEAD of the
    // chain — left by an earlier dropped item advancing this device's local
    // sequence past what actually landed (`OfflineAccountSnapshot.reserve`)
    // — is NOT dead: Stellar only requires `tx.seqNum == account.seqNum +
    // 1`, and the chain's sequence only climbs, so it can still become
    // valid once the transactions between it and the chain's current
    // position land. Re-signing it now would leave two envelopes that could
    // both eventually succeed — a real double-pay, not a hypothetical one.
    if (envelope.sequence >= snapshot.sequence) {
      return const _BadSeqStillWaiting();
    }

    final xdr = const OfflinePaymentBuilder().buildAndSign(
      sender: keyPair,
      snapshot: snapshot,
      destination: envelope.destination,
      amount: envelope.amount,
      nonce: p.nonce,
      asset: PayAsset.configured,
      networkPassphrase: ref.read(networkPassphraseProvider),
      // The ORIGINAL deadline, not a fresh 24h window — a resign must not
      // silently outlive what the receiver was told this payment was valid
      // until (`_isExpired` above still enforces it independently).
      now: p.receivedAt,
    );
    await ref.read(accountSnapshotProvider.notifier).reserve(p.amountRaw);

    return _ResignedPayment(PendingOfflinePayment(
      signedXdr: xdr,
      nonce: p.nonce,
      from: p.from,
      amountRaw: p.amountRaw,
      decimals: p.decimals,
      receivedAt: p.receivedAt,
      resignAttempts: p.resignAttempts + 1,
    ));
  }

  Future<void> _submit(PendingOfflinePayment p) async {
    final networkPassphrase = ref.read(networkPassphraseProvider);
    final hash = AbstractTransaction.fromEnvelopeXdrString(p.signedXdr).hash(Network(networkPassphrase));
    await ref.read(chainSubmitProvider).submit(
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

/// The three things a `tx_bad_seq` rejection can mean for a queued payment
/// — see `PendingOfflinePaymentsNotifier._recoverFromBadSeq`.
sealed class _BadSeqOutcome {
  const _BadSeqOutcome();
}

/// Re-signed against a fresh sequence and still queued, under a NEW
/// idempotency key (the envelope's hash changed) — safe because the old
/// envelope's sequence is now permanently behind the chain and can never
/// itself become valid.
class _ResignedPayment extends _BadSeqOutcome {
  const _ResignedPayment(this.payment);
  final PendingOfflinePayment payment;
}

/// Genuinely unrecoverable: a receiver's copy (no key to re-sign with), a
/// sender past the resign-attempt cap, or an envelope this device can't
/// even parse.
class _BadSeqDead extends _BadSeqOutcome {
  const _BadSeqDead();
}

/// Not dead, but not safe to re-sign yet either — kept queued unchanged so
/// the next retry re-checks it against however far the chain has advanced.
class _BadSeqStillWaiting extends _BadSeqOutcome {
  const _BadSeqStillWaiting();
}

/// Message for an envelope that is genuinely gone (see `_BadSeqDead`,
/// `tx_too_late`, and the resign-attempt cap): distinct wording depending on
/// whether THIS device could have been the one to recover it, since a
/// receiver-side reader who sees "your account changed" about a payment
/// that isn't even theirs is misleading — the sender's own copy of the same
/// payment may still reach the network. Deliberately not
/// `ErrorCopy._submitResultMessages['tx_bad_seq']` ("Your account changed
/// while signing. Please try again.") either way — that wording assumes the
/// person is actively signing right now, which is wrong here: an offline
/// payment can go stale hours later, from a completely unrelated
/// transaction on this device or another one.
String _expiredEnvelopeMessage(PendingOfflinePayment p) => p.resignAttempts > 0
    ? 'This offline payment could no longer be sent after several attempts — your account kept changing on chain before it caught up.'
    : "This offline payment's envelope could no longer be sent. If you sent it, reopening the app may recover it; if you received it, ask the sender to reopen theirs.";

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

final pendingOfflinePaymentsProvider =
    AsyncNotifierProvider<PendingOfflinePaymentsNotifier, List<PendingOfflinePayment>>(
  PendingOfflinePaymentsNotifier.new,
);
