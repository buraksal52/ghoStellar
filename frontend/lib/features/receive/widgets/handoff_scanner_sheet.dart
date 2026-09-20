import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/payments/payment_uri.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/nfc/nfc_service.dart';
import '../../../state/core_providers.dart';
import '../../../state/tap_providers.dart';
import '../../shared/widgets/qr_card.dart';

/// Receive counterpart of the recipient resolver: show, scan, or paste a
/// code. What comes back is either a [ChequeHandoff] (the sender was online)
/// or an [OfflinePayment] (they weren't) — both pop the same way, decided by
/// which one the code actually parses as.
class HandoffScannerSheet extends ConsumerStatefulWidget {
  const HandoffScannerSheet({this.autoScanNfc = false, super.key});

  /// Start waiting for an NFC tap as soon as the sheet opens (when the
  /// device can) — used when the user tapped the big NFC circle on Receive.
  final bool autoScanNfc;

  @override
  ConsumerState<HandoffScannerSheet> createState() =>
      _HandoffScannerSheetState();
}

class _HandoffScannerSheetState extends ConsumerState<HandoffScannerSheet> {
  // Held in a field: `ref` can't be used inside dispose().
  late final NfcService _nfc;
  final _manualController = TextEditingController();
  bool _scanningQr = false;
  bool _showQr = false;
  bool _accepted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nfc = ref.read(nfcServiceProvider);
    if (widget.autoScanNfc && _nfc.isAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(receiveSessionProvider.notifier).beginNfcRead();
      });
    }
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  void _accept(String code) {
    if (_accepted) return;
    final trimmed = code.trim();
    final handoff = ChequeHandoff.tryParse(trimmed);
    if (handoff != null) {
      _accepted = true;
      Navigator.of(context).pop(handoff);
      return;
    }
    final offline = OfflinePayment.tryParse(trimmed);
    if (offline != null) {
      _accepted = true;
      Navigator.of(context).pop(offline);
      return;
    }
    const message = 'Enter a valid payment code from the sender.';
    if (_error != message) setState(() => _error = message);
  }

  void _onDetected(BarcodeCapture capture) {
    final code = capture.barcodes.isNotEmpty
        ? capture.barcodes.first.rawValue
        : null;
    if (code != null) _accept(code);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final session = ref.watch(receiveSessionProvider);
    final request = session.request;
    // A tap is accepted by the session, not by this sheet — so once it moves
    // past waiting (claiming/done) there is nothing left to show here.
    ref.listen(receiveSessionProvider, (_, next) {
      final waiting =
          next.phase == ReceivePhase.offering ||
          next.phase == ReceivePhase.awaitingCheque;
      if (!waiting && !_accepted && mounted) {
        _accepted = true;
        Navigator.of(context).pop();
      }
    });
    final buttonStyle = OutlinedButton.styleFrom(
      side: BorderSide(color: c.border),
      foregroundColor: c.text,
    );
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
              'Receive payment',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            if (_nfc.isAvailable) ...[
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: session.nfcReading
                      ? null
                      : ref.read(receiveSessionProvider.notifier).beginNfcRead,
                  icon: session.nfcReading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.nfc),
                  label: Text(
                    session.nfcReading
                        ? 'Hold near their phone…'
                        : "Tap sender's phone",
                  ),
                  style: buttonStyle,
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => setState(() {
                  _scanningQr = !_scanningQr;
                  _showQr = false;
                  _error = null;
                }),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR Code'),
                style: buttonStyle,
              ),
            ),
            if (_scanningQr) ...[
              const SizedBox(height: 10),
              Text(
                'Scan the code on the sender’s screen after they send the payment.',
                style: TextStyle(fontSize: 13, color: c.muted),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 240,
                child: MobileScanner(
                  onDetect: _onDetected,
                  tapToFocus: true,
                  fit: BoxFit.contain,
                  onDetectError: (_, _) {
                    if (mounted) {
                      setState(() => _error =
                          'Could not read the code. Move farther back and tap the preview to focus.');
                    }
                  },
                ),
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: request == null
                    ? null
                    : () => setState(() {
                        _showQr = !_showQr;
                        _scanningQr = false;
                      }),
                icon: const Icon(Icons.qr_code_2),
                label: Text(_showQr ? 'Hide QR code' : 'Show QR code'),
                style: buttonStyle,
              ),
            ),
            if (_showQr && request != null) ...[
              const SizedBox(height: 14),
              Center(child: QrCard(data: request.toUri())),
            ],
            if (session.nfcError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  session.nfcError!,
                  style: TextStyle(fontSize: 13, color: c.negative),
                ),
              ),
            const SizedBox(height: 14),
            TextField(
              controller: _manualController,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                hintText: 'Or paste sender’s payment code',
                errorText: _error,
                errorMaxLines: 2,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => _accept(_manualController.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: c.primaryText,
                ),
                child: const Text('Use this code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
