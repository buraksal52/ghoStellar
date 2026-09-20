import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/payments/payment_uri.dart';
import '../../../core/theme/app_colors.dart';
import '../../../state/tap_providers.dart';
import '../../shared/widgets/qr_card.dart';

/// Receive counterpart of the recipient resolver: show, scan, or paste a code.
class HandoffScannerSheet extends ConsumerStatefulWidget {
  const HandoffScannerSheet({super.key});

  @override
  ConsumerState<HandoffScannerSheet> createState() =>
      _HandoffScannerSheetState();
}

class _HandoffScannerSheetState extends ConsumerState<HandoffScannerSheet> {
  final _manualController = TextEditingController();
  bool _scanningQr = false;
  bool _showQr = false;
  bool _accepted = false;
  String? _error;

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  void _accept(String code) {
    if (_accepted) return;
    final handoff = ChequeHandoff.tryParse(code.trim());
    if (handoff != null) {
      _accepted = true;
      Navigator.of(context).pop(handoff);
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
    final request = ref.watch(receiveSessionProvider).request;
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
                child: MobileScanner(onDetect: _onDetected),
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
