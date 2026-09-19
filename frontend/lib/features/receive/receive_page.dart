import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../data/api/models/tx_models.dart';
import '../../state/core_providers.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/sync_providers.dart';
import '../../state/wallet_providers.dart';

class ReceivePage extends ConsumerStatefulWidget {
  const ReceivePage({super.key});

  @override
  ConsumerState<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends ConsumerState<ReceivePage> {
  bool _broadcasting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startBroadcastIfSupported());
  }

  @override
  void dispose() {
    ref.read(nfcServiceProvider).stopReceiveBroadcast();
    super.dispose();
  }

  Future<void> _startBroadcastIfSupported() async {
    final nfc = ref.read(nfcServiceProvider);
    final me = ref.read(walletProvider).publicKey;
    if (!nfc.isEmulateSupported || me == null) return;
    await nfc.startReceiveBroadcast(me);
    if (mounted) setState(() => _broadcasting = true);
  }

  Future<void> _claim(String chequeId) async {
    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) return;
    final chequeApi = ref.read(chequeApiProvider);
    final txApi = ref.read(txApiProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final overlay = ref.read(signingOverlayProvider.notifier);

    await overlay.run((report) async {
      final claimXdr = await chequeApi.claimXdr(chequeId);
      report(SigningStep.signing);
      final signed = signing.signTransactionXdr(claimXdr, keyPair);
      report(SigningStep.submitting);
      final result = await txApi.submit(
        idempotencyKey: const Uuid().v4(),
        purpose: 'cheque_claim',
        kind: TxKind.soroban,
        xdr: signed,
      );
      report(SigningStep.confirming);
      await chequeApi.confirmClaim(chequeId, result.hash);
      await chequeApi.ack(chequeId);
      await ref.read(syncProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final nfc = ref.read(nfcServiceProvider);
    final me = ref.watch(walletProvider).publicKey;
    final pending = ref.watch(pendingClaimsProvider);

    return ListView(
      children: [
        SizedBox(
          height: 260,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (nfc.isEmulateSupported)
                  Container(
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
                      child: Icon(Icons.nfc, size: 32, color: c.text),
                    ),
                  )
                else if (me != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: QrImageView(data: me, size: 160),
                  ),
                const SizedBox(height: 18),
                Text(
                  nfc.isEmulateSupported ? 'Ready to Receive' : 'Show this to the sender',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: 250,
                  child: Text(
                    nfc.isEmulateSupported
                        ? "Bring the sender's device close to yours."
                        : 'NFC tap-to-receive needs Android on both sides — scan this QR instead.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: c.muted),
                  ),
                ),
                const SizedBox(height: 14),
                if (_broadcasting)
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
                    onPressed: () => _claim(cheque.id),
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
