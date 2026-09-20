import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/payments/payment_uri.dart';
import '../core/utils/amount_formatter.dart';
import '../data/api/models/cheque_models.dart';
import '../data/api/models/tx_models.dart';
import 'core_providers.dart';
import 'signing_overlay_provider.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

/// Wall clock behind an override point, so expiry logic is testable.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Request nonces this device has already paid, for the lifetime of the app
/// process. A QR that is scanned twice (or a double tap) must not write two
/// cheques. Marked when the cheque is actually created — not when a request
/// is merely scanned — so backing out of a send doesn't burn the code.
class UsedNoncesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String nonce) => state = {...state, nonce};
}

final usedNoncesProvider =
    NotifierProvider<UsedNoncesNotifier, Set<String>>(UsedNoncesNotifier.new);

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
/// 1. Offer a [PaymentRequest] over NFC (Android HCE) and as a QR.
/// 2. Once a sender picks it up, the money still has to be locked on chain
///    by *their* phone. When that's done they hand the cheque id back — over
///    a second NFC tap or a QR the receiver scans ([acceptHandoff]).
/// 3. Independently, `/sync` is polled the whole time, so a missed tap, a
///    QR-only sender, or a lost handoff still ends with the cheque claimed.
///
/// Only cheques that appeared *after* the session started are auto-claimed
/// (older pending ones stay in the manual list), and each cheque is tried at
/// most once — a failing claim must not retry in a loop, it's left to the
/// manual "Claim" button.
class ReceiveSessionNotifier extends Notifier<ReceiveSessionState> {
  static const requestTtl = Duration(minutes: 5);
  static const pollInterval = Duration(seconds: 3);

  /// How long to wait for the sender's chain round trip (create → sign →
  /// submit → confirm) after they picked up the request.
  static const handoffWindow = Duration(minutes: 2);
  static const _rescanDelay = Duration(milliseconds: 500);

  Timer? _poll;
  Timer? _rotate;
  StreamSubscription<void>? _readSub;

  /// Bumped on every start/stop; async work from an older session checks it
  /// and bails instead of touching the new one.
  int _epoch = 0;
  bool _pollBusy = false;
  String? _amount;
  Set<String> _baseline = const {};
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
    _baseline = const {};
    _attempted.clear();

    final nfc = ref.read(nfcServiceProvider);
    if (nfc.isEmulateSupported) {
      _readSub = nfc.onPayloadRead.listen((_) => _onPeerRead(epoch));
    }
    // Offer first: the receiver shouldn't stare at an empty screen while
    // `/sync` loads. Only the polling fallback has to wait for the baseline.
    await _offer(epoch, me);

    final baseline = await _baselineIds();
    if (epoch != _epoch) return;
    _baseline = baseline;
    _poll = Timer.periodic(pollInterval, (_) => _pollOnce(epoch));
  }

  /// Ends the session and stops every radio. Safe to call after the
  /// container is gone (from a widget's dispose).
  void stop() {
    if (!ref.mounted) return;
    _epoch++;
    _cancelTimers();
    final nfc = ref.read(nfcServiceProvider);
    unawaited(nfc.cancelScan());
    unawaited(_safeStopBroadcast());
    state = ReceiveSessionState.idle;
  }

  /// A cheque id handed over by the sender (NFC or scanned QR). Returns
  /// whether it belonged to this session's request.
  Future<bool> acceptHandoff(ChequeHandoff handoff) async {
    final request = state.request;
    if (request == null || handoff.nonce == null || handoff.nonce != request.nonce) return false;
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
    state = ReceiveSessionState(phase: ReceivePhase.offering, request: request);

    // Rotate rather than dead-end: a request nobody picked up in time is
    // replaced by a fresh one while the page is still open.
    _rotate?.cancel();
    _rotate = Timer(requestTtl, () {
      if (epoch == _epoch && state.phase == ReceivePhase.offering) _offer(epoch, me);
    });

    final nfc = ref.read(nfcServiceProvider);
    if (nfc.isEmulateSupported) {
      try {
        await nfc.startBroadcast(request.toUri());
      } catch (_) {
        // NFC unavailable/disabled — the QR of the same request still works.
      }
    }
  }

  void _onPeerRead(int epoch) {
    // A reader may retry GET DATA; only the first read moves the phase.
    if (epoch != _epoch || state.phase != ReceivePhase.offering) return;
    _rotate?.cancel();
    state = ReceiveSessionState(phase: ReceivePhase.awaitingCheque, request: state.request);
    unawaited(_awaitHandoff(epoch));
  }

  /// The roles flip: stop being the tag, become the reader, and wait for the
  /// sender's phone to offer the cheque id.
  Future<void> _awaitHandoff(int epoch) async {
    final nfc = ref.read(nfcServiceProvider);
    await _safeStopBroadcast();
    if (!nfc.isScanSupported) return; // polling / scanned QR will close it.

    final deadline = ref.read(clockProvider)().add(handoffWindow);
    while (epoch == _epoch && state.phase == ReceivePhase.awaitingCheque) {
      final remaining = deadline.difference(ref.read(clockProvider)());
      if (remaining <= Duration.zero) break;

      final payload = await nfc.startScan(timeout: remaining);
      if (epoch != _epoch || state.phase != ReceivePhase.awaitingCheque) return;
      if (payload == null) break;

      final handoff = ChequeHandoff.tryParse(payload);
      if (handoff != null && await acceptHandoff(handoff)) return;
      // Something else was in the field; don't spin on it.
      await Future<void>.delayed(_rescanDelay);
    }

    // Nothing arrived in time: go back to offering rather than dead-ending.
    // Polling is still running and will pick the cheque up if it shows late.
    final me = ref.read(walletProvider).publicKey;
    if (epoch == _epoch && state.phase == ReceivePhase.awaitingCheque && me != null) {
      await _offer(epoch, me);
    }
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

      final request = state.request;
      for (final c in sync.cheques) {
        if (c.receiverAddress != me || c.state != ChequeState.havuzda) continue;
        if (_baseline.contains(c.id) || _attempted.contains(c.id)) continue;
        if (!_matchesAmount(c, request?.amount)) continue;
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
    unawaited(ref.read(nfcServiceProvider).cancelScan());
    await _safeStopBroadcast();

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

  /// Claimable cheques that already exist when the session starts — these
  /// belong in the manual list, not to this session. Waits for the first
  /// `/sync` if it hasn't landed yet, otherwise an old pending cheque would
  /// look "new" and be claimed behind the user's back.
  Future<Set<String>> _baselineIds() async {
    var sync = ref.read(syncProvider).value;
    if (sync == null) {
      try {
        sync = await ref.read(syncProvider.future);
      } catch (_) {
        // /sync failed: nothing to exclude. Worst case an old cheque addressed
        // to us is claimed a little early.
      }
    }
    return _claimableIds(sync?.cheques ?? const []);
  }

  Set<String> _claimableIds(List<Cheque> cheques) {
    final me = ref.read(walletProvider).publicKey;
    return {
      for (final c in cheques)
        if (c.receiverAddress == me && c.state == ChequeState.havuzda) c.id,
    };
  }

  /// Compares in raw integer units with string math — an exact request amount
  /// must equal the cheque exactly, and nothing here touches a double.
  bool _matchesAmount(Cheque cheque, String? requested) {
    if (requested == null) return true;
    return AmountFormatter.toRaw(requested, cheque.decimals) == cheque.amountRaw;
  }

  Future<void> _safeStopBroadcast() async {
    try {
      await ref.read(nfcServiceProvider).stopBroadcast();
    } catch (_) {
      // Nothing was being broadcast / NFC unavailable.
    }
  }

  void _cancelTimers() {
    _poll?.cancel();
    _rotate?.cancel();
    _readSub?.cancel();
    _poll = null;
    _rotate = null;
    _readSub = null;
  }
}

final receiveSessionProvider =
    NotifierProvider<ReceiveSessionNotifier, ReceiveSessionState>(ReceiveSessionNotifier.new);
