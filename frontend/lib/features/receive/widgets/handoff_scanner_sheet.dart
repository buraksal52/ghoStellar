import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/payments/payment_uri.dart';
import '../../../core/theme/app_colors.dart';

/// Scans the QR the sender's phone shows once their cheque is locked, and
/// pops the parsed [ChequeHandoff]. This is the no-NFC twin of the second
/// tap: same payload, different carrier.
class HandoffScannerSheet extends StatefulWidget {
  const HandoffScannerSheet({super.key});

  @override
  State<HandoffScannerSheet> createState() => _HandoffScannerSheetState();
}

class _HandoffScannerSheetState extends State<HandoffScannerSheet> {
  String? _error;

  void _onDetected(BarcodeCapture capture) {
    final code = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (code == null) return;
    final handoff = ChequeHandoff.tryParse(code);
    if (handoff != null) {
      Navigator.of(context).pop(handoff);
      return;
    }
    // The scanner fires many times per second for the same frame; only
    // rebuild when the message actually changes.
    const message = "That QR code isn't a ghoStellar payment.";
    if (_error != message) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Scan the sender's code", style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'It appears on their phone once the payment is sent.',
            style: TextStyle(fontSize: 13, color: c.muted),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 260,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: MobileScanner(onDetect: _onDetected),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(fontSize: 13, color: c.negative)),
            ),
        ],
      ),
    );
  }
}
