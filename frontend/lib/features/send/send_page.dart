import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/api_error.dart';

import '../../core/config/pay_asset.dart';
import '../../core/payments/payment_uri.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../data/api/models/tx_models.dart';
import '../../data/nfc/nfc_service.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' show KeyPair;

import '../../data/storage/offline_payment_store.dart';
import '../../data/stellar/offline_payment_builder.dart';
import '../../state/core_providers.dart';
import '../../state/home_providers.dart';
import '../../state/offline_providers.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/sync_providers.dart';
import '../../state/tap_providers.dart';
import '../../state/wallet_providers.dart';
import '../shared/widgets/qr_card.dart';
import 'widgets/recipient_resolver_sheet.dart';

/// Whatever the sender is currently handing the receiver: a locked cheque
/// (the normal, online path) or — when [SendPage] couldn't reach the
/// backend — a signed classic payment built and verified entirely offline.
/// Both carry a URI and a display amount; only how they were produced, and
/// what guarantees they carry, differs.
sealed class _Handoff {
  const _Handoff();
  String get uri;
  String? get amount;
}

class _OnlineHandoff extends _Handoff {
  const _OnlineHandoff(this.cheque);
  final ChequeHandoff cheque;
  @override
  String get uri => cheque.toUri();
  @override
  String? get amount => cheque.amount;
}

/// No escrow, no 7-day recall — see `OfflinePayment`'s own doc comment for
/// why. [_handoffPanel] discloses this plainly rather than reusing the
/// online copy.
class _OfflineHandoffToDeliver extends _Handoff {
  const _OfflineHandoffToDeliver(this.payment);
  final OfflinePayment payment;
  @override
  String get uri => payment.toUri();
  @override
  String? get amount => payment.amount;
}

class SendPage extends ConsumerStatefulWidget {
  const SendPage({super.key});

  @override
  ConsumerState<SendPage> createState() => _SendPageState();
}

class _SendPageState extends ConsumerState<SendPage> {
  /// How long the sender keeps offering the cheque id — matches the
  /// receiver's wait for it (`ReceiveSessionNotifier.handoffWindow`).
  static const _handoffWindow = ReceiveSessionNotifier.handoffWindow;

  final _amountController = TextEditingController(text: '50.00');
  // Held in a field: `ref` can't be used inside dispose().
  late final NfcService _nfc;
  PaymentRequest? _request;

  /// The receiver asked for an amount and it is fixed until the user taps
  /// "Change" — so a tap-to-pay can't be nudged into a different sum by an
  /// accidental keystroke.
  bool _amountUnlocked = false;

  _Handoff? _handoff;
  bool _delivered = false;
  Timer? _handoffTimer;
  StreamSubscription<void>? _deliveredSub;

  bool get _amountLocked => _request?.amount != null && !_amountUnlocked;

  @override
  void initState() {
    super.initState();
    _nfc = ref.read(nfcServiceProvider);
  }

  @override
  void dispose() {
    _handoffTimer?.cancel();
    _deliveredSub?.cancel();
    if (_handoff != null) _stopHandoffNfc();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _resolveRecipient({bool autoNfc = false}) async {
    final request = await showModalBottomSheet<PaymentRequest>(
      context: context,
      isScrollControlled: true,
      // See ReceivePage._openReceiveOptions: the shell's navigator would
      // leave the app bar and bottom nav outside the scrim.
      useRootNavigator: true,
      builder: (_) => RecipientResolverSheet(autoScanNfc: autoNfc),
    );
    if (request == null || !mounted) return;
    setState(() {
      _request = request;
      _amountUnlocked = false;
      final amount = request.amount;
      if (amount != null) _amountController.text = amount;
    });
  }

  Future<void> _sendCheque() async {
    final request = _request;
    final amount = _amountController.text.trim();
    if (request == null || !AmountFormatter.isValidPositiveDecimal(amount)) return;

    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) return;

    final chequeApi = ref.read(chequeApiProvider);
    final txApi = ref.read(txApiProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final overlay = ref.read(signingOverlayProvider.notifier);

    _Handoff? handoff;
    final ok = await overlay.run<bool>((report) async {
      final nonce = request.nonce;
      try {
        // The request id is what makes the server refuse a second cheque
        // for the same request (`cheque.request_used`).
        final created = await chequeApi.create(
          receiver: request.destination,
          amount: amount,
          requestId: nonce,
        );

        report(SigningStep.signing);
        final signedLockXdr = signing.signTransactionXdr(created.lockXdr, keyPair);

        report(SigningStep.submitting);
        final submitResult = await txApi.submit(
          idempotencyKey: const Uuid().v4(),
          purpose: 'cheque_lock',
          kind: TxKind.soroban,
          xdr: signedLockXdr,
        );

        // The on-chain debit has already happened. Refresh even if the
        // subsequent backend confirmation or preauth upload fails.
        ref.invalidate(balancesProvider);

        report(SigningStep.confirming);
        await chequeApi.confirmLock(created.chequeId, submitResult.hash);

        final signedEntry = signing.signAuthEntryXdr(created.preauthEntryXdr, keyPair);
        await chequeApi.preauth(created.chequeId, signedEntry);

        await ref.read(syncProvider.notifier).refresh();
        ref.invalidate(balancesProvider);
        handoff = _OnlineHandoff(ChequeHandoff(
          chequeId: created.chequeId,
          from: keyPair.accountId,
          amount: amount,
          nonce: nonce,
        ));
        return true;
      } on ApiException catch (e) {
        // Only a request that came with a nonce (scanned/tapped, not a
        // manually pasted address) can be answered offline — the receiver's
        // memo check has nothing to verify a bare address against.
        if (e.code != 'network.error' || nonce == null) rethrow;
        handoff = _OfflineHandoffToDeliver(await _buildOfflinePayment(keyPair, request, amount, nonce));
        return true;
      }
    });

    if (ok != true || !mounted) return;
    setState(() {
      _request = null;
      _amountUnlocked = false;
    });
    final h = handoff;
    if (h != null) await _offerHandoff(h);
  }

  /// Builds and signs a classic payment directly from the cached account
  /// snapshot — no network call. Throws a plain [Exception] (shown by the
  /// overlay like any other failure) when there is nothing cached to build
  /// from, or the cached balance can't cover it; the caller is already
  /// inside `overlay.run`.
  Future<OfflinePayment> _buildOfflinePayment(
    KeyPair keyPair,
    PaymentRequest request,
    String amount,
    String nonce,
  ) async {
    // Awaited, not a plain `.value` read: the cache load from disk may not
    // have finished yet (this can be the very first thing that touches it),
    // and a spurious "no offline data" would be wrong, not just early.
    final snapshot = await ref.read(accountSnapshotProvider.future);
    if (snapshot == null) {
      throw Exception("No offline balance data yet — connect once, then you can pay while offline.");
    }
    final amountRaw = AmountFormatter.toRaw(amount, snapshot.decimals);
    if (amountRaw == null || BigInt.parse(amountRaw) > BigInt.parse(snapshot.availableRaw)) {
      throw Exception('Not enough balance cached from the last time you were online.');
    }

    final xdr = const OfflinePaymentBuilder().buildAndSign(
      sender: keyPair,
      snapshot: snapshot,
      destination: request.destination,
      amount: amount,
      nonce: nonce,
      asset: PayAsset.configured,
      networkPassphrase: ref.read(networkPassphraseProvider),
    );

    // Irrevocable from here (the payment is signed): record it before
    // anything else can fail, exactly like the online path marks the
    // request spent by creating the cheque.
    //
    // Crucially, the SENDER also enqueues it in the same durable,
    // self-retrying queue the receiver uses (`pendingOfflinePaymentsProvider`)
    // — not just the in-memory handoff shown for a few seconds. Without
    // this, a handoff that the receiver never actually collects (missed
    // NFC tap, closed app, no QR scan) left the signed payment nowhere:
    // gone the moment the handoff window closed, even though the balance
    // was already reserved and the nonce already spent. The transaction's
    // own hash is the idempotency key (`offline_providers.dart`), so it's
    // safe for both sides to end up submitting the same payment.
    await ref.read(accountSnapshotProvider.notifier).reserve(amountRaw);
    await ref.read(offlinePaymentStoreProvider).markSpent(nonce);
    ref.read(offlineSpentRequestIdsProvider.notifier).add(nonce);
    await ref.read(pendingOfflinePaymentsProvider.notifier).add(PendingOfflinePayment(
          signedXdr: xdr,
          nonce: nonce,
          from: keyPair.accountId,
          amountRaw: amountRaw,
          decimals: snapshot.decimals,
          receivedAt: ref.read(clockProvider)(),
        ));

    return OfflinePayment(signedXdr: xdr, nonce: nonce, from: keyPair.accountId, amount: amount);
  }

  /// The cheque is locked; let the receiver's phone collect it without
  /// waiting for their `/sync`. NFC where the device can, and always as a QR
  /// so a receiver without NFC (or a missed tap) still closes the payment —
  /// and their polling closes it even if neither is used.
  ///
  /// An Android sender alternates reader and tag windows so either Android or
  /// iPhone receivers can collect the handoff. An iPhone waits for the
  /// "Tap receiver's phone" button ([_beginHandoffRead]).
  Future<void> _offerHandoff(_Handoff handoff) async {
    setState(() {
      _handoff = handoff;
      _delivered = false;
    });
    _handoffTimer?.cancel();
    _handoffTimer = Timer(_handoffWindow, _endHandoff);

    final nfc = _nfc;
    if (!nfc.isAvailable) return;
    _deliveredSub?.cancel();
    _deliveredSub = nfc.onDelivered.listen((_) {
      if (mounted) setState(() => _delivered = true);
    });
    if (!nfc.canBeTag) return;
    try {
      await nfc.start(role: nfc.senderRole, offer: handoff.uri);
    } catch (_) {
      // NFC unavailable/disabled — the QR of the same payload still works.
    }
  }

  /// The iPhone's (reader-only) start: pull the receiver's tag and write the
  /// handoff to it in one tap.
  Future<void> _beginHandoffRead() async {
    final handoff = _handoff;
    if (handoff == null) return;
    try {
      await _nfc.start(role: NfcRole.reader, offer: handoff.uri);
    } catch (_) {
      // NFC unavailable/disabled — the QR still works.
    }
  }

  void _endHandoff() {
    _handoffTimer?.cancel();
    _deliveredSub?.cancel();
    _stopHandoffNfc();
    if (mounted) {
      setState(() {
        _handoff = null;
        _delivered = false;
      });
    }
  }

  void _stopHandoffNfc() {
    unawaited(_nfc.stop().catchError((_) {}));
  }

  Widget _ring(AppColors c, IconData icon, {required VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 184,
        height: 184,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: c.border),
        ),
        child: Container(
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.surface,
            border: Border.all(color: c.border),
          ),
          child: Icon(icon, size: 32, color: c.text),
        ),
      ),
    );
  }

  Widget _handoffPanel(BuildContext context, AppColors c, _Handoff handoff) {
    final nfc = _nfc;
    final amount = handoff.amount;
    return Column(
      children: [
        if (handoff is _OfflineHandoffToDeliver)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(color: c.infoCard, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded, size: 16, color: c.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Sent while offline — not escrowed, and can't be recalled. "
                    "It reaches the network once either of you is back online.",
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        if (_delivered)
          _ring(c, Icons.check_rounded, onTap: null)
        else if (nfc.canBeTag)
          _ring(c, Icons.nfc, onTap: null)
        else
          QrCard(data: handoff.uri),
        const SizedBox(height: 18),
        Text(
          _delivered ? 'Delivered' : 'Payment sent',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 260,
          child: Text(
            _delivered
                ? 'They can collect it now.'
                : nfc.canBeTag
                    ? 'Hold your phones together again so they can collect'
                        '${amount == null ? '' : ' $amount ${PayAsset.configured.label}'} — or let them scan the code.'
                    : 'Let them scan this code to collect'
                        '${amount == null ? '' : ' $amount ${PayAsset.configured.label}'}.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: c.muted),
          ),
        ),
        // Before the QR, so it stays reachable on a short screen.
        if (nfc.isAvailable && !nfc.canBeTag && !_delivered)
          TextButton.icon(
            onPressed: _beginHandoffRead,
            icon: Icon(Icons.nfc, size: 18, color: c.text),
            label: Text("Tap receiver's phone", style: TextStyle(fontSize: 13, color: c.text)),
          ),
        TextButton(onPressed: _endHandoff, child: const Text('Done')),
        if (nfc.canBeTag && !_delivered) ...[
          const SizedBox(height: 4),
          QrCard(data: handoff.uri),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final overlayStep = ref.watch(signingOverlayProvider).step;
    // Keeps `/sync` loaded while the user picks a recipient, so the scan's
    // "already paid" pre-check has data to check against.
    ref.watch(paidRequestIdsProvider);
    final request = _request;
    final canSend = request != null &&
        AmountFormatter.isValidPositiveDecimal(_amountController.text) &&
        overlayStep == SigningStep.idle;
    final handoff = _handoff;

    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send', style: TextStyle(fontSize: 13, color: c.textSecondary)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amountController,
                      readOnly: _amountLocked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: Theme.of(context).textTheme.displayLarge,
                      decoration: const InputDecoration(
                        // The global input theme fills fields; the amount sits directly on the card.
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '0.00',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(PayAsset.configured.label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.info)),
                ],
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: _resolveRecipient,
                child: Text(
                  request == null ? 'Tap to choose recipient' : 'to ${_short(request.destination)}',
                  style: TextStyle(fontSize: 13, color: c.muted, fontFamily: 'monospace'),
                ),
              ),
              if (_amountLocked) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'They asked for this amount.',
                        style: TextStyle(fontSize: 12, color: c.textSecondary),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _amountUnlocked = true),
                      child: Text(
                        'Change',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.info),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (handoff != null)
          _handoffPanel(context, c, handoff)
        else ...[
          SizedBox(
            height: 220,
            child: Center(
              child: _ring(
                c,
                canSend ? Icons.north_rounded : Icons.nfc,
                // No recipient yet: the circle starts listening for a tap.
                onTap: canSend ? _sendCheque : () => _resolveRecipient(autoNfc: true),
              ),
            ),
          ),
          Center(
            child: Column(
              children: [
                Text(
                  canSend ? 'Tap to Send' : 'Find recipient',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                // Wide enough that the sentence breaks in two even lines
                // rather than leaving a lone word on a third one.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Text(
                    canSend
                        ? 'Your phone signs on this device, then hands the payment over.'
                        : "Bring your phone close to the recipient's device, or scan/paste their code.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: c.muted),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Secure on-device signing · recoverable if unclaimed after 7 days.',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
          ),
        ),
      ],
    );
  }

  String _short(String address) =>
      address.length <= 10 ? address : '${address.substring(0, 4)}...${address.substring(address.length - 4)}';
}
