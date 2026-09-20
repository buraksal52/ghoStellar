import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/payments/payment_uri.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../data/api/models/tx_models.dart';
import '../../data/nfc/nfc_service.dart';
import '../../state/core_providers.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/sync_providers.dart';
import '../../state/tap_providers.dart';
import '../../state/wallet_providers.dart';
import '../shared/widgets/qr_card.dart';
import 'widgets/recipient_resolver_sheet.dart';

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

  ChequeHandoff? _handoff;
  bool _delivered = false;
  Timer? _handoffTimer;
  StreamSubscription<void>? _readSub;

  bool get _amountLocked => _request?.amount != null && !_amountUnlocked;

  @override
  void initState() {
    super.initState();
    _nfc = ref.read(nfcServiceProvider);
  }

  @override
  void dispose() {
    _handoffTimer?.cancel();
    _readSub?.cancel();
    if (_handoff != null) _stopHandoffBroadcast();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _resolveRecipient({bool autoNfc = false}) async {
    final request = await showModalBottomSheet<PaymentRequest>(
      context: context,
      isScrollControlled: true,
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

    ChequeHandoff? handoff;
    final ok = await overlay.run<bool>((report) async {
      final created = await chequeApi.create(receiver: request.destination, amount: amount);
      // The cheque exists now: this request must not be payable a second time.
      final nonce = request.nonce;
      if (nonce != null) ref.read(usedNoncesProvider.notifier).add(nonce);

      report(SigningStep.signing);
      final signedLockXdr = signing.signTransactionXdr(created.lockXdr, keyPair);

      report(SigningStep.submitting);
      final submitResult = await txApi.submit(
        idempotencyKey: const Uuid().v4(),
        purpose: 'cheque_lock',
        kind: TxKind.soroban,
        xdr: signedLockXdr,
      );

      report(SigningStep.confirming);
      await chequeApi.confirmLock(created.chequeId, submitResult.hash);

      final signedEntry = signing.signAuthEntryXdr(created.preauthEntryXdr, keyPair);
      await chequeApi.preauth(created.chequeId, signedEntry);

      await ref.read(syncProvider.notifier).refresh();
      handoff = ChequeHandoff(
        chequeId: created.chequeId,
        from: keyPair.accountId,
        amount: amount,
        nonce: nonce,
      );
      return true;
    });

    if (ok != true || !mounted) return;
    setState(() {
      _request = null;
      _amountUnlocked = false;
    });
    final h = handoff;
    if (h != null) await _offerHandoff(h);
  }

  /// The cheque is locked; let the receiver's phone collect it without
  /// waiting for their `/sync`. NFC where the device can, and always as a QR
  /// so a receiver without NFC (or a missed tap) still closes the payment —
  /// and their polling closes it even if neither is used.
  Future<void> _offerHandoff(ChequeHandoff handoff) async {
    setState(() {
      _handoff = handoff;
      _delivered = false;
    });
    _handoffTimer?.cancel();
    _handoffTimer = Timer(_handoffWindow, _endHandoff);

    final nfc = _nfc;
    if (!nfc.isEmulateSupported) return;
    _readSub?.cancel();
    _readSub = nfc.onPayloadRead.listen((_) {
      if (mounted) setState(() => _delivered = true);
    });
    try {
      await nfc.startBroadcast(handoff.toUri());
    } catch (_) {
      // NFC unavailable/disabled — the QR of the same payload still works.
    }
  }

  void _endHandoff() {
    _handoffTimer?.cancel();
    _readSub?.cancel();
    _stopHandoffBroadcast();
    if (mounted) {
      setState(() {
        _handoff = null;
        _delivered = false;
      });
    }
  }

  void _stopHandoffBroadcast() {
    unawaited(_nfc.stopBroadcast().catchError((_) {}));
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

  Widget _handoffPanel(BuildContext context, AppColors c, ChequeHandoff handoff) {
    final nfc = _nfc;
    final amount = handoff.amount;
    return Column(
      children: [
        if (_delivered)
          _ring(c, Icons.check_rounded, onTap: null)
        else if (nfc.isEmulateSupported)
          _ring(c, Icons.nfc, onTap: null)
        else
          QrCard(data: handoff.toUri()),
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
                : nfc.isEmulateSupported
                    ? 'Hold your phones together again so they can collect'
                        '${amount == null ? '' : ' $amount XLM'} — or let them scan the code.'
                    : 'Let them scan this code to collect'
                        '${amount == null ? '' : ' $amount XLM'}.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: c.muted),
          ),
        ),
        // Before the QR, so it stays reachable on a short screen.
        TextButton(onPressed: _endHandoff, child: const Text('Done')),
        if (nfc.isEmulateSupported && !_delivered) ...[
          const SizedBox(height: 4),
          QrCard(data: handoff.toUri()),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final overlayStep = ref.watch(signingOverlayProvider).step;
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
                  Text('XLM', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.info)),
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
                SizedBox(
                  width: 230,
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
          child: Text(
            'Secure on-device signing · recoverable if unclaimed after 7 days.',
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
        ),
      ],
    );
  }

  String _short(String address) =>
      address.length <= 10 ? address : '${address.substring(0, 4)}...${address.substring(address.length - 4)}';
}
