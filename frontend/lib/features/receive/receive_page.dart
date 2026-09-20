import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/pay_asset.dart';
import '../../core/payments/payment_uri.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../state/core_providers.dart';
import '../../state/inbox_providers.dart';
import '../../state/sync_providers.dart';
import '../../state/tap_providers.dart';
import '../../state/wallet_providers.dart';
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
    final valid =
        value.isEmpty || AmountFormatter.isValidPositiveDecimal(value);
    setState(
      () => _amountError = valid
          ? null
          : 'Enter a valid amount, or leave it empty.',
    );
    _debounce?.cancel();
    if (!valid) return;
    _debounce = Timer(
      _amountDebounce,
      () => _session.start(amount: value.isEmpty ? null : value),
    );
  }

  Future<void> _openReceiveOptions({bool autoNfc = false}) async {
    // Either a ChequeHandoff (the sender was online) or an OfflinePayment
    // (they weren't) — HandoffScannerSheet decides which by what parses.
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (_) => HandoffScannerSheet(autoScanNfc: autoNfc),
    );
    if (result == null || !mounted) return;
    final accepted = switch (result) {
      ChequeHandoff h => await _session.acceptHandoff(h),
      OfflinePayment p => await _session.acceptOfflinePayment(p),
      _ => false,
    };
    if (!accepted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That code isn't for this request.")),
      );
    }
  }

  Widget _nfcRing(AppColors c, IconData icon, {VoidCallback? onTap}) {
    return SizedBox(
      height: 220,
      child: Center(
        child: Semantics(
          button: onTap != null,
          label: onTap == null ? null : "Open receive options",
          child: GestureDetector(
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
          ),
        ),
      ),
    );
  }

  /// The inline NFC read button shown in `awaitingCheque` (the second tap):
  /// idle "Tap sender's phone", or — while [ReceiveSessionNotifier.beginNfcRead]
  /// is waiting for a tap — a spinner and "Hold near their phone…", like the
  /// sender's "Tap receiver's phone" after "Payment sent". In `idle`/`offering`
  /// the same button lives in [HandoffScannerSheet], as on Send.
  Widget _nfcButton(AppColors c, ReceiveSessionState session) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        TextButton.icon(
          onPressed: session.nfcReading ? null : _session.beginNfcRead,
          icon: session.nfcReading
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.text),
                )
              : Icon(Icons.nfc, size: 18, color: c.text),
          label: Text(
            session.nfcReading ? 'Hold near their phone…' : "Tap sender's phone",
            style: TextStyle(fontSize: 13, color: c.text),
          ),
        ),
        if (session.nfcError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              session.nfcError!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: c.negative),
            ),
          ),
      ],
    );
  }

  Widget _title(BuildContext context, String title, String body, AppColors c) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: c.muted),
          ),
        ),
      ],
    );
  }

  List<Widget> _hero(
    BuildContext context,
    AppColors c,
    ReceiveSessionState session,
  ) {
    final nfc = ref.read(nfcServiceProvider);
    final request = session.request;
    final amount = request?.amount;
    final asked = amount == null
        ? ''
        : '${AmountFormatter.trimTrailingZeros(amount)} ${PayAsset.configured.label}';

    switch (session.phase) {
      case ReceivePhase.done:
        return [
          _nfcRing(c, Icons.check_rounded),
          _title(
            context,
            'Payment received',
            session.offlineSettlementPending
                ? "Saved — it'll settle once either of you is back online."
                : 'It is in your balance now.',
            c,
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () =>
                _session.start(amount: _amountController.text.trim()),
            child: const Text('New request'),
          ),
        ];
      case ReceivePhase.claiming:
        return [
          _nfcRing(c, Icons.south_rounded),
          _title(
            context,
            'Receiving…',
            'Signing on your device — this takes a few seconds.',
            c,
          ),
        ];
      case ReceivePhase.awaitingCheque:
        return [
          Stack(
            alignment: Alignment.center,
            children: [
              _nfcRing(
                c,
                Icons.nfc,
                onTap: () => _openReceiveOptions(autoNfc: true),
              ),
              const SizedBox(
                width: 184,
                height: 184,
                child: IgnorePointer(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ],
          ),
          _title(
            context,
            'Waiting for the payment',
            nfc.canBeTag
                ? 'The sender is signing. Hold the phones together again when they ask, or scan their code.'
                : 'The sender is signing. When they show "Payment sent", tap their phone again — or scan their code.',
            c,
          ),
          if (nfc.isAvailable) _nfcButton(c, session),
          TextButton.icon(
            onPressed: _openReceiveOptions,
            icon: Icon(Icons.qr_code_scanner, size: 18, color: c.text),
            label: Text(
              "Scan sender's code",
              style: TextStyle(fontSize: 13, color: c.text),
            ),
          ),
        ];
      case ReceivePhase.idle:
      case ReceivePhase.offering:
        return [
          _nfcRing(
            c,
            Icons.nfc,
            onTap: () => _openReceiveOptions(autoNfc: true),
          ),
          _title(
            context,
            'Ready to Receive',
            "Bring your phone close to the sender's device, or tap to show, scan or paste a payment code.",
            c,
          ),
          if (asked.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Requesting $asked',
              style: TextStyle(fontSize: 13, color: c.textSecondary),
            ),
          ],
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
    final pendingOffline = ref.watch(pendingHandoffsProvider).value ?? const [];

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
              Text(
                'Receive',
                style: TextStyle(fontSize: 13, color: c.textSecondary),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amountController,
                      enabled:
                          me != null &&
                          (live || session.phase == ReceivePhase.idle),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: Theme.of(context).textTheme.displayLarge,
                      onChanged: _onAmountChanged,
                      decoration: InputDecoration(
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        hintText: '0.00',
                        semanticCounterText: 'Optional amount to receive',
                        errorText: _amountError,
                        errorMaxLines: 2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    PayAsset.configured.label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.info,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Request an amount (optional)',
                style: TextStyle(
                  fontSize: 13,
                  color: c.muted,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ..._hero(context, c, session),
        const SizedBox(height: 20),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Secure on-device signing · payments arrive in your wallet.',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (pendingOffline.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: c.infoCard,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded, size: 18, color: c.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    pendingOffline.length == 1
                        ? "Saved — will be claimed automatically once you're back online."
                        : "${pendingOffline.length} payments saved — will be claimed once you're back online.",
                    style: TextStyle(fontSize: 13, color: c.textSecondary),
                  ),
                ),
              ],
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
                    decoration: BoxDecoration(
                      color: c.surfaceRaised,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(Icons.south_rounded, size: 16, color: c.text),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(cheque.amountRaw, cheque.decimals))} ${PayAsset.configured.label}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
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
              child: Text(
                'No payments waiting right now.',
                style: TextStyle(color: c.muted, fontSize: 13),
              ),
            ),
          ),
      ],
    );
  }
}
