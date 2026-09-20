import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/payments/payment_uri.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../state/core_providers.dart';
import '../../state/sync_providers.dart';
import '../../state/tap_providers.dart';
import '../../state/wallet_providers.dart';
import '../shared/widgets/qr_card.dart';
import 'widgets/handoff_scanner_sheet.dart';

/// The receiver's side of a tap/scan payment: shows a payment request (NFC +
/// QR), then collects the cheque the sender writes — see
/// [ReceiveSessionNotifier] for the sequence and the fallbacks.
class ReceivePage extends ConsumerStatefulWidget {
  const ReceivePage({super.key});

  @override
  ConsumerState<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends ConsumerState<ReceivePage> {
  static const _amountDebounce = Duration(milliseconds: 600);

  final _amountController = TextEditingController();
  late final ReceiveSessionNotifier _session;
  Timer? _debounce;
  String? _amountError;
  bool _showQr = false;

  @override
  void initState() {
    super.initState();
    _session = ref.read(receiveSessionProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) => _session.start());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _amountController.dispose();
    // Not synchronously: changing provider state while the tree is being
    // torn down is an error, and the radios only need to stop "soon".
    final session = _session;
    Future.microtask(session.stop);
    super.dispose();
  }

  void _onAmountChanged(String text) {
    final value = text.trim();
    final valid = value.isEmpty || AmountFormatter.isValidPositiveDecimal(value);
    setState(() => _amountError = valid ? null : 'Enter a valid amount, or leave it empty.');
    _debounce?.cancel();
    if (!valid) return;
    _debounce = Timer(_amountDebounce, () => _session.start(amount: value.isEmpty ? null : value));
  }

  Future<void> _scanHandoff() async {
    final handoff = await showModalBottomSheet<ChequeHandoff>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const HandoffScannerSheet(),
    );
    if (handoff == null) return;
    final accepted = await _session.acceptHandoff(handoff);
    if (!accepted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That code isn't for this request.")),
      );
    }
  }

  Widget _nfcRing(AppColors c, IconData icon) {
    return Container(
      width: 184,
      height: 184,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.border)),
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
    );
  }

  Widget _title(BuildContext context, String title, String body, AppColors c) {
    return Column(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        SizedBox(
          width: 260,
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: c.muted),
          ),
        ),
      ],
    );
  }

  List<Widget> _hero(BuildContext context, AppColors c, ReceiveSessionState session) {
    final nfc = ref.read(nfcServiceProvider);
    final request = session.request;
    final amount = request?.amount;
    final asked = amount == null ? '' : '${AmountFormatter.trimTrailingZeros(amount)} XLM';

    switch (session.phase) {
      case ReceivePhase.done:
        return [
          _nfcRing(c, Icons.check_rounded),
          const SizedBox(height: 18),
          _title(context, 'Payment received', 'It is in your balance now.', c),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => _session.start(amount: _amountController.text.trim()),
            child: const Text('New request'),
          ),
        ];
      case ReceivePhase.claiming:
        return [
          _nfcRing(c, Icons.south_rounded),
          const SizedBox(height: 18),
          _title(context, 'Receiving…', 'Signing on your device — this takes a few seconds.', c),
        ];
      case ReceivePhase.awaitingCheque:
        return [
          Stack(
            alignment: Alignment.center,
            children: [
              _nfcRing(c, Icons.nfc),
              const SizedBox(width: 184, height: 184, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 18),
          _title(
            context,
            'Waiting for the payment',
            nfc.isScanSupported
                ? 'The sender is signing. Hold the phones together again when they ask, or scan their code.'
                : 'The sender is signing. Scan the code on their screen when it appears.',
            c,
          ),
          TextButton.icon(
            onPressed: _scanHandoff,
            icon: Icon(Icons.qr_code_scanner, size: 18, color: c.text),
            label: Text("Scan sender's code", style: TextStyle(fontSize: 13, color: c.text)),
          ),
        ];
      case ReceivePhase.idle:
      case ReceivePhase.offering:
        final uri = request?.toUri();
        final showRing = nfc.isEmulateSupported;
        return [
          if (showRing)
            _nfcRing(c, Icons.nfc)
          else if (uri != null)
            QrCard(data: uri),
          const SizedBox(height: 18),
          _title(
            context,
            showRing ? 'Ready to Receive' : 'Show this to the sender',
            showRing
                ? "Bring the sender's device close — or show them your QR code."
                : 'NFC tap-to-receive needs Android on both sides — have them scan this QR instead.',
            c,
          ),
          if (asked.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Requesting $asked', style: TextStyle(fontSize: 13, color: c.textSecondary)),
          ],
          if (showRing && uri != null) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => setState(() => _showQr = !_showQr),
              icon: Icon(Icons.qr_code_2, size: 18, color: c.text),
              label: Text(
                _showQr ? 'Hide QR code' : 'Show QR code',
                style: TextStyle(fontSize: 13, color: c.text),
              ),
            ),
            if (_showQr) ...[const SizedBox(height: 8), QrCard(data: uri)],
          ],
          TextButton.icon(
            onPressed: _scanHandoff,
            icon: Icon(Icons.qr_code_scanner, size: 18, color: c.text),
            label: Text("Scan sender's code", style: TextStyle(fontSize: 13, color: c.text)),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final me = ref.watch(walletProvider).publicKey;
    final pending = ref.watch(pendingClaimsProvider);
    final session = ref.watch(receiveSessionProvider);
    final live = session.phase == ReceivePhase.offering;

    return ListView(
      children: [
        // minHeight, not a fixed height: the content (~280-310px) is taller than
        // 260 and a fixed box overflows; this keeps it centered when short and
        // lets it grow (the ListView scrolls) when not.
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 260),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ..._hero(context, c, session),
                const SizedBox(height: 14),
                if (session.phase != ReceivePhase.idle && session.phase != ReceivePhase.done)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(color: c.infoCard, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 7, height: 7, decoration: BoxDecoration(color: c.positive, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text('Secure session active', style: TextStyle(fontSize: 13, color: c.textSecondary)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (me != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: TextField(
              controller: _amountController,
              enabled: live || session.phase == ReceivePhase.idle,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: _onAmountChanged,
              decoration: InputDecoration(
                hintText: 'Request an amount (optional)',
                suffixText: 'XLM',
                errorText: _amountError,
              ),
            ),
          ),
        if (pending.isNotEmpty)
          for (final cheque in pending)
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(9)),
                    child: Icon(Icons.south_rounded, size: 16, color: c.text),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(cheque.amountRaw, cheque.decimals))} XLM',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'From ${cheque.senderAddress.substring(0, 4)}...${cheque.senderAddress.substring(cheque.senderAddress.length - 4)}',
                          style: TextStyle(fontSize: 12, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => _session.claim(cheque.id),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.primary,
                      foregroundColor: c.primaryText,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                    ),
                    child: const Text('Claim'),
                  ),
                ],
              ),
            )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text('No payments waiting right now.', style: TextStyle(color: c.muted, fontSize: 13)),
            ),
          ),
      ],
    );
  }
}
