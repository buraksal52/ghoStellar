import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/payments/payment_uri.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/nfc/nfc_service.dart';
import '../../../state/core_providers.dart';
import '../../../state/tap_providers.dart';

/// Resolves who to pay — and, when the receiver asked for one, how much —
/// as a [PaymentRequest], via, in order of how the design prioritizes them:
/// a live NFC tap (Android only), a scanned QR code (the counterpart's
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
  ConsumerState<RecipientResolverSheet> createState() => _RecipientResolverSheetState();
}

class _RecipientResolverSheetState extends ConsumerState<RecipientResolverSheet> {
  // Held in a field: `ref` can't be used inside dispose().
  late final NfcService _nfc;
  bool _scanningNfc = false;
  bool _scanningQr = false;
  final _manualController = TextEditingController();
  String? _scanError;
  String? _manualError;

  @override
  void initState() {
    super.initState();
    _nfc = ref.read(nfcServiceProvider);
    if (widget.autoScanNfc && _nfc.isScanSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scanNfc();
      });
    }
  }

  @override
  void dispose() {
    // Closing the sheet must end the reader session, not leave it polling.
    _nfc.cancelScan();
    _manualController.dispose();
    super.dispose();
  }

  /// Turns whatever was read/typed into a request we're willing to pay, or a
  /// message saying why not. Returns null on success (after popping).
  String? _accept(String? raw) {
    final request = PaymentRequest.tryParse(raw);
    if (request == null) return "That isn't a payment request or Stellar address.";
    if (request.isExpiredAt(ref.read(clockProvider)())) {
      return 'This request has expired — ask them to show a new one.';
    }
    final nonce = request.nonce;
    if (nonce != null && ref.read(usedNoncesProvider).contains(nonce)) {
      return 'You already paid this request.';
    }
    Navigator.of(context).pop(request);
    return null;
  }

  Future<void> _scanNfc() async {
    setState(() {
      _scanningNfc = true;
      _scanError = null;
    });
    try {
      final payload = await _nfc.startScan();
      if (!mounted || payload == null) return;
      final problem = _accept(payload);
      if (problem != null) setState(() => _scanError = problem);
    } finally {
      if (mounted) setState(() => _scanningNfc = false);
    }
  }

  void _onQrDetected(BarcodeCapture capture) {
    final barcodes = capture.barcodes;
    final code = barcodes.isNotEmpty ? barcodes.first.rawValue : null;
    if (code == null) return;
    final problem = _accept(code);
    // The scanner fires many times per second for the same frame; only rebuild
    // when the message actually changes.
    if (problem != null && _scanError != problem) setState(() => _scanError = problem);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Padding(
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
          Text('Find recipient', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (_nfc.isScanSupported)
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _scanningNfc ? null : _scanNfc,
                icon: _scanningNfc
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.nfc),
                label: Text(_scanningNfc ? 'Hold near their phone…' : 'Tap their phone'),
                style: OutlinedButton.styleFrom(side: BorderSide(color: c.border), foregroundColor: c.text),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton.icon(
              onPressed: () => setState(() {
                _scanningQr = !_scanningQr;
                _scanError = null;
              }),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR Code'),
              style: OutlinedButton.styleFrom(side: BorderSide(color: c.border), foregroundColor: c.text),
            ),
          ),
          if (_scanningQr)
            SizedBox(
              height: 240,
              child: MobileScanner(onDetect: _onQrDetected),
            ),
          if (_scanError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_scanError!, style: TextStyle(fontSize: 13, color: c.negative)),
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
                  setState(() => _manualError = PaymentRequest.tryParse(v) == null
                      ? 'Enter a valid Stellar address (starts with G, 56 characters).'
                      : problem);
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: c.primary, foregroundColor: c.primaryText),
              child: const Text('Use this address'),
            ),
          ),
        ],
      ),
    );
  }
}
