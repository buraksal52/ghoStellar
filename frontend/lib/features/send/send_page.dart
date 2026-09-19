import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../data/api/models/tx_models.dart';
import '../../state/core_providers.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/sync_providers.dart';
import '../../state/wallet_providers.dart';
import 'widgets/recipient_resolver_sheet.dart';

class SendPage extends ConsumerStatefulWidget {
  const SendPage({super.key});

  @override
  ConsumerState<SendPage> createState() => _SendPageState();
}

class _SendPageState extends ConsumerState<SendPage> {
  final _amountController = TextEditingController(text: '50.00');
  String? _recipient;

  Future<void> _resolveRecipient() async {
    final address = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const RecipientResolverSheet(),
    );
    if (address != null) setState(() => _recipient = address);
  }

  Future<void> _sendCheque() async {
    final amount = _amountController.text.trim();
    final recipient = _recipient;
    if (recipient == null || !AmountFormatter.isValidPositiveDecimal(amount)) return;

    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) return;

    final chequeApi = ref.read(chequeApiProvider);
    final txApi = ref.read(txApiProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final overlay = ref.read(signingOverlayProvider.notifier);

    await overlay.run((report) async {
      final created = await chequeApi.create(receiver: recipient, amount: amount);

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
      if (mounted) setState(() => _recipient = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final overlayStep = ref.watch(signingOverlayProvider).step;
    final canSend = _recipient != null &&
        AmountFormatter.isValidPositiveDecimal(_amountController.text) &&
        overlayStep == SigningStep.idle;

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
                  SizedBox(
                    width: 190,
                    child: TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: Theme.of(context).textTheme.displayLarge,
                      decoration: const InputDecoration(border: InputBorder.none, hintText: '0.00'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Text('XLM', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.info)),
                ],
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: _resolveRecipient,
                child: Text(
                  _recipient == null
                      ? 'Tap to choose recipient'
                      : 'to ${_short(_recipient!)}',
                  style: TextStyle(fontSize: 13, color: c.muted, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 220,
          child: Center(
            child: GestureDetector(
              onTap: canSend ? _sendCheque : _resolveRecipient,
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
                  child: Icon(Icons.nfc, size: 32, color: c.text),
                ),
              ),
            ),
          ),
        ),
        Center(
          child: Column(
            children: [
              Text(
                canSend ? 'Tap to Send' : 'Choose a recipient first',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: 230,
                child: Text(
                  "Bring your phone close to the recipient's device, or scan/paste their address.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: c.muted),
                ),
              ),
            ],
          ),
        ),
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
