import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/config/pay_asset.dart';
import '../core/errors/api_error.dart';
import '../core/errors/error_copy.dart';
import '../core/payments/payment_uri.dart';
import '../core/utils/amount_formatter.dart';
import '../data/api/models/cheque_models.dart';
import '../data/nfc/nfc_service.dart';
import '../data/storage/handoff_inbox.dart';
import '../data/storage/offline_payment_store.dart';
import '../data/stellar/offline_payment_verifier.dart';
import 'claim_core.dart';
import 'core_providers.dart';
import 'inbox_providers.dart';
import 'offline_providers.dart';
import 'signing_overlay_provider.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

export 'core_providers.dart' show clockProvider;

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
    this.offlineSettlementPending = false,
    this.nfcReading = false,
    this.nfcError,
  });

  final ReceivePhase phase;
  final PaymentRequest? request;
  final String? claimedChequeId;

  /// True when [phase] is `done` because a *classic offline payment* was
  /// accepted (verified locally, queued for submission) rather than a
  /// cheque actually claimed on chain — the balance isn't real yet.
  final bool offlineSettlementPending;

  /// True while [ReceiveSessionNotifier.beginNfcRead] is actively waiting for
  /// a tap — drives the "Hold near their phone…" button state. Cleared
  /// whenever the phase moves on (a plain `ReceiveSessionState(...)`
  /// construction, as every phase transition uses, defaults it back to
  /// false).
  final bool nfcReading;

  /// A timeout or hardware error from the last [ReceiveSessionNotifier.beginNfcRead].
  final String? nfcError;

  static const idle = ReceiveSessionState();

  /// Copies only the NFC-read display fields, keeping everything else (phase,
  /// request, …) — used so toggling the read indicator never disturbs the
  /// rest of the session state.
  ReceiveSessionState copyWith({bool? nfcReading, String? nfcError, bool clearNfcError = false}) {
    return ReceiveSessionState(
      phase: phase,
      request: request,
      claimedChequeId: claimedChequeId,
      offlineSettlementPending: offlineSettlementPending,
      nfcReading: nfcReading ?? this.nfcReading,
      nfcError: clearNfcError ? null : (nfcError ?? this.nfcError),
    );
  }
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

  /// How long [beginNfcRead] waits for a tap before giving up — matches the
  /// sender-side wait in `RecipientResolverSheet`.
  static const nfcWait = Duration(seconds: 30);

  Timer? _poll;
  Timer? _rotate;
  Timer? _awaitTimer;
  Timer? _nfcReadTimer;
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

  /// Starts an NFC read and shows a "Hold near their phone…" state until
  /// either a tap lands or [nfcWait] passes with nothing found.
  ///
  /// On a device that can only be the reader (an iPhone), this pulls the
  /// other phone's payload and writes our request to it in the same tap —
  /// call it for the first tap and again for the second (the cheque
  /// handoff). On a device that is already the tag (Android), the radio is
  /// already presenting via [_offer]/[setOffer]; this only surfaces the
  /// waiting state, since re-starting the tag session would reset the
  /// broadcast mid-flight.
  Future<void> beginNfcRead() async {
    final uri = _offerUri;
    final nfc = ref.read(nfcServiceProvider);
    if (uri == null || !nfc.isAvailable) return;

    state = state.copyWith(nfcReading: true, clearNfcError: true);
    _nfcReadTimer?.cancel();
    _nfcReadTimer = Timer(nfcWait, () {
      if (!state.nfcReading) return;
      state = state.copyWith(
        nfcReading: false,
        nfcError: nfc.canBeTag
            ? 'No phone found. Hold the phones back to back and try again, or scan their code.'
            : "No phone found. An iPhone can only tap an Android phone — for another iPhone, scan their code.",
      );
    });

    if (nfc.canBeTag) return; // Already presenting — nothing more to start.
    try {
      await nfc.start(role: NfcRole.reader, offer: uri);
    } catch (_) {
      _nfcReadTimer?.cancel();
      state = state.copyWith(
        nfcReading: false,
        nfcError: 'NFC is turned off or unavailable. Scan their code instead.',
      );
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

  /// A signed classic payment handed over by a sender who couldn't reach
  /// the backend (NFC or scanned QR) — the sender-is-offline path. Verified
  /// entirely from the signed XDR itself ([OfflinePaymentVerifier]); nothing
  /// from [payment]'s own fields is trusted. Returns whether it was accepted.
  Future<bool> acceptOfflinePayment(OfflinePayment payment) async {
    final request = state.request;
    final me = ref.read(walletProvider).publicKey;
    final requestNonce = request?.nonce;
    if (request == null || me == null || requestNonce == null) return false;
    if (payment.nonce != requestNonce) return false;
    if (state.phase != ReceivePhase.offering && state.phase != ReceivePhase.awaitingCheque) {
      return false;
    }

    final requestedAmount = request.amount;
    final minAmountRaw =
        requestedAmount == null ? null : AmountFormatter.toRaw(requestedAmount, classicStellarDecimals);
    final result = const OfflinePaymentVerifier().verify(
      signedXdr: payment.signedXdr,
      expectedDestination: me,
      requestNonce: requestNonce,
      asset: PayAsset.configured,
      decimals: classicStellarDecimals,
      minAmountRaw: minAmountRaw,
      networkPassphrase: ref.read(networkPassphraseProvider),
    );
    if (!result.isValid) return false;

    _cancelTimers();
    await _safeStopNfc();
    await ref.read(pendingOfflinePaymentsProvider.notifier).add(PendingOfflinePayment(
          signedXdr: payment.signedXdr,
          nonce: payment.nonce,
          from: result.from!,
          amountRaw: result.amount!,
          decimals: result.decimals!,
          receivedAt: ref.read(clockProvider)(),
        ));
    state = ReceiveSessionState(phase: ReceivePhase.done, request: request, offlineSettlementPending: true);
    return true;
  }

  /// Claims [chequeId] with the signing overlay showing progress and any
  /// error — used by the session's happy path and the manual "Claim" button,
  /// where a person is watching. Returns false on failure.
  Future<bool> claim(String chequeId) async {
    final overlay = ref.read(signingOverlayProvider.notifier);
    final ok = await overlay.run<bool>((report) async {
      final keyPair = ref.read(walletProvider).keyPair;
      // Thrown INSIDE overlay.run (rather than returning false before it
      // starts) so a locked wallet shows the overlay's error instead of the
      // "Claim" button silently doing nothing.
      if (keyPair == null) {
        throw ApiException(code: 'auth.invalid_token', message: 'wallet is locked');
      }
      await performClaim(ref, keyPair, chequeId, onStep: report);
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
    if (handoff != null) {
      unawaited(acceptHandoff(handoff));
      return;
    }
    final offline = OfflinePayment.tryParse(payload);
    if (offline != null) unawaited(acceptOfflinePayment(offline));
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

    // Not through claim(): a real failure (e.g. "already expired") should
    // still tell the user why, but a transient one (typically offline)
    // should be saved rather than just shown and forgotten.
    final keyPair = ref.read(walletProvider).keyPair;
    var success = false;
    if (keyPair != null) {
      final overlay = ref.read(signingOverlayProvider.notifier);
      overlay.setStep(SigningStep.preparing);
      try {
        await performClaim(ref, keyPair, chequeId, onStep: overlay.setStep);
        overlay.setStep(SigningStep.done);
        success = true;
      } catch (e) {
        if (classifyClaimFailure(e) == ClaimOutcome.gone) {
          overlay.state = SigningOverlayState(
            step: SigningStep.error,
            errorMessage: e is ApiException ? ErrorCopy.forException(e) : e.toString(),
          );
        } else {
          await ref.read(pendingHandoffsProvider.notifier).add(PendingHandoff(
                chequeId: chequeId,
                from: request?.destination ?? '',
                amount: request?.amount,
                nonce: request?.nonce,
                receivedAt: ref.read(clockProvider)(),
              ));
          overlay.dismiss();
        }
      }
    }
    if (epoch != _epoch) return;

    if (success) {
      _cancelTimers();
      state = ReceiveSessionState(
        phase: ReceivePhase.done,
        request: request,
        claimedChequeId: chequeId,
      );
      return;
    }
    // Failed or saved for later. Resume offering so the session isn't stuck;
    // the inbox and the manual "Claim" button now own getting this cheque
    // the rest of the way.
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
    _nfcReadTimer?.cancel();
    _deliveredSub?.cancel();
    _peerSub?.cancel();
    _poll = null;
    _rotate = null;
    _awaitTimer = null;
    _nfcReadTimer = null;
    _deliveredSub = null;
    _peerSub = null;
  }
}

final receiveSessionProvider =
    NotifierProvider<ReceiveSessionNotifier, ReceiveSessionState>(ReceiveSessionNotifier.new);
