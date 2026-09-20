import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/payments/payment_uri.dart';
import '../core/utils/amount_formatter.dart';
import '../data/api/models/cheque_models.dart';
import '../data/api/models/tx_models.dart';
import '../data/nfc/nfc_service.dart';
import 'core_providers.dart';
import 'signing_overlay_provider.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

/// Wall clock behind an override point, so expiry logic is testable.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Payment-request ids the server already holds a cheque of mine for, read
/// from the same `/sync` the rest of the app polls — so "you already paid
/// this" survives an app restart and a second device, unlike an in-memory
/// set.
///
/// A best-effort *pre*-check only: `/sync` lists non-terminal cheques, so a
/// request whose cheque has already closed, or one a different sender paid,
/// isn't visible here. The authority is the server's unique index — a second
/// `POST /cheques` for the same request answers `cheque.request_used`.
final paidRequestIdsProvider = Provider<Set<String>>((ref) {
  final sync = ref.watch(syncProvider).value;
  final me = ref.watch(walletProvider).publicKey;
  if (sync == null || me == null) return const {};
  return {
    for (final c in sync.cheques)
      if (c.senderAddress == me && c.requestId != null) c.requestId!,
  };
});

enum ReceivePhase {
  /// No session (page just opened or left).
  idle,

  /// Showing/broadcasting a payment request.
  offering,

  /// A sender picked the request up; waiting for their cheque.
  awaitingCheque,

  /// A cheque was found and is being claimed.
  claiming,

  /// Claimed.
  done,
}

class ReceiveSessionState {
  const ReceiveSessionState({
    this.phase = ReceivePhase.idle,
    this.request,
    this.claimedChequeId,
  });

  final ReceivePhase phase;
  final PaymentRequest? request;
  final String? claimedChequeId;

  static const idle = ReceiveSessionState();
}

/// The receiver's half of a tap/scan payment.
///
/// 1. Offer a [PaymentRequest] over NFC and as a QR. An Android receiver is
///    the tag and starts presenting at once; an iPhone can only read, so it
///    waits for the user to start a read ([beginNfcRead]) — Apple wants NFC
///    sessions user-initiated.
/// 2. Once a sender picks it up, the money still has to be locked on chain
///    by *their* phone. When that's done they hand the cheque id back — over
///    NFC (written to our tag, or read from theirs) or a QR the receiver
///    scans ([acceptHandoff]). Roles never flip: a tap is a two-way exchange.
/// 3. Independently, `/sync` is polled the whole time, so a missed tap, a
///    QR-only sender, or a lost handoff still ends with the cheque claimed.
///
/// Only cheques that answer a request *this session issued* are auto-claimed
/// (matched by the `requestId` the sender echoed, which the server stores);
/// anything else pending stays in the manual list. Each cheque is tried at
/// most once — a failing claim must not retry in a loop, it's left to the
/// manual "Claim" button.
class ReceiveSessionNotifier extends Notifier<ReceiveSessionState> {
  static const requestTtl = Duration(minutes: 5);
  static const pollInterval = Duration(seconds: 3);

  /// How long to wait for the sender's chain round trip (create → sign →
  /// submit → confirm) after they picked up the request.
  static const handoffWindow = Duration(minutes: 2);

  Timer? _poll;
  Timer? _rotate;
  Timer? _awaitTimer;
  StreamSubscription<void>? _deliveredSub;
  StreamSubscription<String>? _peerSub;

  /// Whether the NFC session for this offer is running (so a rotated request
  /// only swaps the payload instead of restarting the radio).
  bool _nfcStarted = false;
  String? _offerUri;

  /// Bumped on every start/stop; async work from an older session checks it
  /// and bails instead of touching the new one.
  int _epoch = 0;
  bool _pollBusy = false;
  String? _amount;

  /// Every request id this page has offered, including rotated-out ones: a
  /// sender may have scanned an earlier QR and only now finish paying.
  /// Kept across restarts of the offer (an amount edit) and cleared on stop.
  final Set<String> _issuedNonces = {};
  final Set<String> _attempted = {};

  @override
  ReceiveSessionState build() {
    ref.onDispose(_cancelTimers);
    return ReceiveSessionState.idle;
  }

  /// Starts (or restarts) a session. [amount] is the optional requested
  /// amount; anything that isn't a valid positive decimal means "sender
  /// chooses".
  Future<void> start({String? amount}) async {
    final me = ref.read(walletProvider).publicKey;
    if (me == null) return;

    _cancelTimers();
    final epoch = ++_epoch;
    _amount = amount != null && AmountFormatter.isValidPositiveDecimal(amount) ? amount : null;
    _nfcStarted = false;

    final nfc = ref.read(nfcServiceProvider);
    if (nfc.isAvailable) {
      _deliveredSub = nfc.onDelivered.listen((_) => _onPeerRead(epoch));
      _peerSub = nfc.onPeerPayload.listen((payload) => _onPeerPayload(epoch, payload));
    }
    _poll = Timer.periodic(pollInterval, (_) => _pollOnce(epoch));
    await _offer(epoch, me);
  }

  /// Ends the session and stops every radio. Safe to call after the
  /// container is gone (from a widget's dispose).
  void stop() {
    if (!ref.mounted) return;
    _epoch++;
    _cancelTimers();
    _issuedNonces.clear();
    _attempted.clear();
    unawaited(_safeStopNfc());
    state = ReceiveSessionState.idle;
  }

  /// Starts a one-shot NFC read, for a device that can only be the reader
  /// (an iPhone): it pulls the other phone's payload and writes our request
  /// to it in the same tap. Call it for the first tap and again for the
  /// second (the cheque handoff). A no-op where we are the tag already.
  Future<void> beginNfcRead() async {
    final uri = _offerUri;
    final nfc = ref.read(nfcServiceProvider);
    if (uri == null || !nfc.canRead || nfc.canBeTag) return;
    try {
      await nfc.start(role: NfcRole.reader, offer: uri);
    } catch (_) {
      // NFC off/unavailable — the QR of the same request still works.
    }
  }

  /// A cheque id handed over by the sender (NFC or scanned QR). Returns
  /// whether it belonged to this session's request.
  Future<bool> acceptHandoff(ChequeHandoff handoff) async {
    final nonce = handoff.nonce;
    if (nonce == null || !_issuedNonces.contains(nonce)) return false;
    if (state.phase != ReceivePhase.offering && state.phase != ReceivePhase.awaitingCheque) {
      return false;
    }
    await _autoClaim(_epoch, handoff.chequeId);
    return true;
  }

  /// Claims [chequeId]: claim-xdr → sign → submit → confirm → ack → refresh.
  /// Used by the session's auto path and by the manual "Claim" button.
  /// Returns false when something failed (the signing overlay has shown why).
  Future<bool> claim(String chequeId) async {
    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) return false;
    final chequeApi = ref.read(chequeApiProvider);
    final txApi = ref.read(txApiProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final overlay = ref.read(signingOverlayProvider.notifier);

    final ok = await overlay.run<bool>((report) async {
      final claimXdr = await chequeApi.claimXdr(chequeId);
      report(SigningStep.signing);
      final signed = signing.signTransactionXdr(claimXdr, keyPair);
      report(SigningStep.submitting);
      final result = await txApi.submit(
        idempotencyKey: const Uuid().v4(),
        purpose: 'cheque_claim',
        kind: TxKind.soroban,
        xdr: signed,
      );
      report(SigningStep.confirming);
      await chequeApi.confirmClaim(chequeId, result.hash);
      await chequeApi.ack(chequeId);
      await ref.read(syncProvider.notifier).refresh();
      return true;
    });
    return ok ?? false;
  }

  // ---- internals ---------------------------------------------------------

  Future<void> _offer(int epoch, String me) async {
    if (epoch != _epoch) return;
    final now = ref.read(clockProvider)();
    final request = PaymentRequest(
      destination: me,
      amount: _amount,
      nonce: const Uuid().v4(),
      expiresAt: now.add(requestTtl),
    );
    _issuedNonces.add(request.nonce!);
    state = ReceiveSessionState(phase: ReceivePhase.offering, request: request);

    // Rotate rather than dead-end: a request nobody picked up in time is
    // replaced by a fresh one while the page is still open.
    _rotate?.cancel();
    _rotate = Timer(requestTtl, () {
      if (epoch == _epoch && state.phase == ReceivePhase.offering) _offer(epoch, me);
    });

    _offerUri = request.toUri();
    final nfc = ref.read(nfcServiceProvider);
    if (nfc.canBeTag) {
      try {
        if (_nfcStarted) {
          await nfc.setOffer(_offerUri);
        } else {
          await nfc.start(role: nfc.receiverRole, offer: _offerUri);
          _nfcStarted = true;
        }
      } catch (_) {
        // NFC unavailable/disabled — the QR of the same request still works.
      }
    }
  }

  void _onPeerRead(int epoch) {
    // A reader may retry; only the first one moves the phase.
    if (epoch != _epoch || state.phase != ReceivePhase.offering) return;
    _rotate?.cancel();
    state = ReceiveSessionState(phase: ReceivePhase.awaitingCheque, request: state.request);

    // Wait a bounded time for the sender's chain round trip, then go back to
    // offering rather than dead-ending. Polling keeps running and still
    // catches a cheque that shows up late.
    _awaitTimer?.cancel();
    _awaitTimer = Timer(handoffWindow, () {
      final me = ref.read(walletProvider).publicKey;
      if (epoch == _epoch && state.phase == ReceivePhase.awaitingCheque && me != null) {
        _offer(epoch, me);
      }
    });
  }

  void _onPeerPayload(int epoch, String payload) {
    if (epoch != _epoch) return;
    final handoff = ChequeHandoff.tryParse(payload);
    if (handoff != null) unawaited(acceptHandoff(handoff));
  }

  Future<void> _pollOnce(int epoch) async {
    if (_pollBusy || epoch != _epoch) return;
    if (state.phase == ReceivePhase.claiming || state.phase == ReceivePhase.done) return;
    _pollBusy = true;
    try {
      final sync = await ref.read(syncApiProvider).sync();
      if (epoch != _epoch) return;
      final me = ref.read(walletProvider).publicKey;
      if (me == null) return;

      for (final c in sync.cheques) {
        if (c.receiverAddress != me || c.state != ChequeState.havuzda) continue;
        final id = c.requestId;
        if (id == null || !_issuedNonces.contains(id) || _attempted.contains(c.id)) continue;
        await _autoClaim(epoch, c.id);
        break;
      }
    } catch (_) {
      // Transient (offline, 5xx) — the next tick retries.
    } finally {
      _pollBusy = false;
    }
  }

  Future<void> _autoClaim(int epoch, String chequeId) async {
    if (epoch != _epoch) return;
    if (state.phase == ReceivePhase.claiming || state.phase == ReceivePhase.done) return;
    if (!_attempted.add(chequeId)) return;

    final request = state.request;
    state = ReceiveSessionState(phase: ReceivePhase.claiming, request: request);
    _rotate?.cancel();
    _awaitTimer?.cancel();
    _nfcStarted = false;
    await _safeStopNfc();

    final ok = await claim(chequeId);
    if (epoch != _epoch) return;

    if (ok) {
      _cancelTimers();
      state = ReceiveSessionState(
        phase: ReceivePhase.done,
        request: request,
        claimedChequeId: chequeId,
      );
      return;
    }
    // Failed (the overlay explained why). Leave it to the manual button and
    // resume offering so the session isn't stuck.
    final me = ref.read(walletProvider).publicKey;
    if (me != null) await _offer(epoch, me);
  }

  Future<void> _safeStopNfc() async {
    try {
      await ref.read(nfcServiceProvider).stop();
    } catch (_) {
      // Nothing was running / NFC unavailable.
    }
  }

  void _cancelTimers() {
    _poll?.cancel();
    _rotate?.cancel();
    _awaitTimer?.cancel();
    _deliveredSub?.cancel();
    _peerSub?.cancel();
    _poll = null;
    _rotate = null;
    _awaitTimer = null;
    _deliveredSub = null;
    _peerSub = null;
  }
}

final receiveSessionProvider =
    NotifierProvider<ReceiveSessionNotifier, ReceiveSessionState>(ReceiveSessionNotifier.new);
