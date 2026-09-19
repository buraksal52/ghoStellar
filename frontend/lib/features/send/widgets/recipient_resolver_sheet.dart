import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/app_colors.dart';
import '../../../state/core_providers.dart';

/// Resolves the recipient's Stellar address via, in order of how the design
/// prioritizes them: a live NFC tap (Android only), a scanned QR code (the
/// counterpart's Receive screen renders one), or manual entry/paste as the
/// always-available fallback — matches the design's "More ways to send"
/// affordance rather than inventing a new UI concept.
class RecipientResolverSheet extends ConsumerStatefulWidget {
  const RecipientResolverSheet({super.key});

  @override
  ConsumerState<RecipientResolverSheet> createState() => _RecipientResolverSheetState();
}

class _RecipientResolverSheetState extends ConsumerState<RecipientResolverSheet> {
  bool _scanningNfc = false;
  bool _scanningQr = false;
  final _manualController = TextEditingController();

  Future<void> _scanNfc() async {
    setState(() => _scanningNfc = true);
    final nfc = ref.read(nfcServiceProvider);
    try {
      final address = await nfc.startSendScan();
      if (address != null && mounted) Navigator.of(context).pop(address);
    } finally {
      if (mounted) setState(() => _scanningNfc = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final nfc = ref.read(nfcServiceProvider);

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
          if (nfc.isEmulateSupported)
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
              onPressed: () => setState(() => _scanningQr = !_scanningQr),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR Code'),
              style: OutlinedButton.styleFrom(side: BorderSide(color: c.border), foregroundColor: c.text),
            ),
          ),
          if (_scanningQr)
            SizedBox(
              height: 240,
              child: MobileScanner(
                onDetect: (capture) {
                  final barcodes = capture.barcodes;
                  final code = barcodes.isNotEmpty ? barcodes.first.rawValue : null;
                  if (code != null) Navigator.of(context).pop(code);
                },
              ),
            ),
          const SizedBox(height: 14),
          TextField(
            controller: _manualController,
            decoration: const InputDecoration(hintText: 'Or paste recipient address (G...)'),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () {
                final v = _manualController.text.trim();
                if (v.isNotEmpty) Navigator.of(context).pop(v);
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
