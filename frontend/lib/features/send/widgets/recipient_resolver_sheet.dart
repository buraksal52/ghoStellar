import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/payments/payment_uri.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/nfc/nfc_service.dart';
import '../../../state/core_providers.dart';
import '../../../state/offline_providers.dart';
import '../../../state/tap_providers.dart';
import '../../../state/wallet_providers.dart';
import '../../shared/widgets/qr_card.dart';

/// Resolves who to pay — and, when the receiver asked for one, how much —
/// as a [PaymentRequest], via, in order of how the design prioritizes them:
/// a live NFC tap (Android, or an iPhone against an Android), a scanned QR code (the counterpart's
/// Receive screen renders one), or manual entry/paste as the always-available
/// fallback — matches the design's "More ways to send" affordance rather
/// than inventing a new UI concept. All three go through the same
/// [_accept] check, so a request is judged identically however it arrived.
///
/// Pops the request, or null if dismissed.
class RecipientResolverSheet extends ConsumerStatefulWidget {
  const RecipientResolverSheet({this.autoScanNfc = false, super.key});

  /// Start listening for an NFC tap as soon as the sheet opens (when the
  /// device can) — used when the user tapped the big NFC circle on Send.
  final bool autoScanNfc;

  @override
  ConsumerState<RecipientResolverSheet> createState() =>
      _RecipientResolverSheetState();
}

class _RecipientResolverSheetState
    extends ConsumerState<RecipientResolverSheet> {
  /// How long a tap is awaited before the sheet says nothing was found.
  static const _nfcWait = Duration(seconds: 30);

  // Held in a field: `ref` can't be used inside dispose().
  late final NfcService _nfc;
  StreamSubscription<String>? _peerSub;
  Timer? _nfcTimeout;
  bool _scanningNfc = false;
  bool _scanningQr = false;
  bool _showQr = false;
  final _manualController = TextEditingController();
  String? _scanError;
  String? _manualError;

  @override
  void initState() {
    super.initState();
    _nfc = ref.read(nfcServiceProvider);
    if (widget.autoScanNfc && _nfc.isAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scanNfc();
      });
    }
  }

  @override
  void dispose() {
    // Closing the sheet must end the NFC session, not leave it running.
    _nfcTimeout?.cancel();
    _peerSub?.cancel();
    _nfc.stop();
    _manualController.dispose();
    super.dispose();
  }

  /// Turns whatever was read/typed into a request we're willing to pay, or a
  /// message saying why not. Returns null on success (after popping).
  String? _accept(String? raw) {
    final request = PaymentRequest.tryParse(raw);
    if (request == null) {
      return "That isn't a payment request or Stellar address.";
    }
    if (request.isExpiredAt(ref.read(clockProvider)())) {
      return 'This request has expired — ask them to show a new one.';
    }
    final nonce = request.nonce;
    if (nonce != null &&
        (ref.read(paidRequestIdsProvider).contains(nonce) ||
            ref.read(offlineSpentRequestIdsProvider).contains(nonce))) {
      return 'You already paid this request.';
    }
    Navigator.of(context).pop(request);
    return null;
  }

  /// Listens for the other phone's payment request. The Android sender reads
  /// the receiver's continuously presented HCE tag; an iPhone does the same
  /// through a Core NFC session.
  Future<void> _scanNfc() async {
    setState(() {
      _scanningNfc = true;
      _scanError = null;
    });
    await _peerSub?.cancel();
    _peerSub = _nfc.onPeerPayload.listen((payload) {
      final problem = _accept(payload);
      // Keep listening after a bad one — the right phone may still arrive.
      if (problem != null && mounted) setState(() => _scanError = problem);
    });
    _nfcTimeout?.cancel();
    _nfcTimeout = Timer(_nfcWait, () => _stopNfc(nothingFound: true));
    try {
      // Use a stable reader role for Android-to-Android discovery. Reader
      // mode disables this phone's HCE, so alternating here only adds missed
      // windows and can synchronize both phones as readers.
      await _nfc.start(
        role: _nfc.canBeTag ? NfcRole.reader : _nfc.senderRole,
        offer: null,
      );
    } catch (_) {
      _stopNfc(unavailable: true);
    }
  }

  void _stopNfc({bool nothingFound = false, bool unavailable = false}) {
    _nfcTimeout?.cancel();
    _peerSub?.cancel();
    _nfc.stop();
    if (!mounted) return;
    setState(() {
      _scanningNfc = false;
      if (unavailable) {
        _scanError =
            'NFC is turned off or unavailable. Scan their QR code instead.';
      } else if (nothingFound) {
        _scanError = _nfc.canBeTag
            ? 'No phone found. Hold the phones back to back and try again, or scan their QR code.'
            : "No phone found. An iPhone can only tap an Android phone — for another iPhone, scan their QR code.";
      }
    });
  }

  void _onQrDetected(BarcodeCapture capture) {
    final barcodes = capture.barcodes;
    final code = barcodes.isNotEmpty ? barcodes.first.rawValue : null;
    if (code == null) return;
    final problem = _accept(code);
    // The scanner fires many times per second for the same frame; only rebuild
    // when the message actually changes.
    if (problem != null && _scanError != problem) {
      setState(() => _scanError = problem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final address = ref.watch(walletProvider).publicKey;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Find recipient',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            if (_nfc.isAvailable)
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _scanningNfc ? null : _scanNfc,
                  icon: _scanningNfc
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.nfc),
                  label: Text(
                    _scanningNfc ? 'Hold near their phone…' : 'Tap their phone',
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: c.border),
                    foregroundColor: c.text,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => setState(() {
                  _scanningQr = !_scanningQr;
                  _showQr = false;
                  _scanError = null;
                }),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR Code'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: c.border),
                  foregroundColor: c.text,
                ),
              ),
            ),
            if (_scanningQr)
              SizedBox(
                height: 240,
                child: MobileScanner(onDetect: _onQrDetected),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: address == null
                    ? null
                    : () => setState(() {
                        _showQr = !_showQr;
                        _scanningQr = false;
                        _scanError = null;
                      }),
                icon: const Icon(Icons.qr_code_2),
                label: Text(_showQr ? 'Hide QR code' : 'Show QR code'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: c.border),
                  foregroundColor: c.text,
                ),
              ),
            ),
            if (_showQr && address != null) ...[
              const SizedBox(height: 14),
              Center(child: QrCard(data: address)),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Your wallet address',
                  style: TextStyle(fontSize: 13, color: c.muted),
                ),
              ),
            ],
            if (_scanError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _scanError!,
                  style: TextStyle(fontSize: 13, color: c.negative),
                ),
              ),
            const SizedBox(height: 14),
            TextField(
              controller: _manualController,
              onChanged: (_) {
                if (_manualError != null) setState(() => _manualError = null);
              },
              decoration: InputDecoration(
                hintText: 'Or paste recipient address or payment link',
                errorText: _manualError,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  final v = _manualController.text.trim();
                  if (v.isEmpty) return;
                  final problem = _accept(v);
                  if (problem != null) {
                    setState(
                      () => _manualError = PaymentRequest.tryParse(v) == null
                          ? 'Enter a valid Stellar address (starts with G, 56 characters).'
                          : problem,
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: c.primaryText,
                ),
                child: const Text('Use this address'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
