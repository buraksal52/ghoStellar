import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_colors.dart';
import '../../core/errors/api_error.dart';
import '../../core/errors/error_copy.dart';
import '../../core/utils/amount_formatter.dart';
import '../../data/api/models/tx_models.dart';
import '../../data/storage/local_activity_log.dart';
import '../../state/activity_providers.dart';
import '../../state/core_providers.dart';
import '../../state/home_providers.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/sync_providers.dart';
import '../../state/wallet_providers.dart';

/// Pool deposits lock withdrawals for a period after each deposit — the
/// exact contract constant should be confirmed against
/// contracts/soroban/pay-escrow before shipping; 7 days matches the
/// design copy and SERVICE.md's description of the MVP contract.
const _poolLockDays = 7;

class PoolPage extends ConsumerStatefulWidget {
  const PoolPage({super.key});

  @override
  ConsumerState<PoolPage> createState() => _PoolPageState();
}

class _PoolPageState extends ConsumerState<PoolPage> {
  bool _isDeposit = true;
  final _amountController = TextEditingController();
  String? _lockError;

  Future<void> _submit() async {
    final amount = _amountController.text.trim();
    if (!AmountFormatter.isValidPositiveDecimal(amount)) return;
    setState(() => _lockError = null);

    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) return;

    final poolApi = ref.read(poolApiProvider);
    final txApi = ref.read(txApiProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final overlay = ref.read(signingOverlayProvider.notifier);
    final log = ref.read(localActivityLogProvider);

    try {
      await overlay.run((report) async {
        final xdr = _isDeposit ? await poolApi.depositXdr(amount) : await poolApi.withdrawXdr(amount);
        report(SigningStep.signing);
        final signed = signing.signTransactionXdr(xdr, keyPair);
        report(SigningStep.submitting);
        await txApi.submit(
          idempotencyKey: const Uuid().v4(),
          purpose: _isDeposit ? 'pool_deposit' : 'pool_withdraw',
          kind: TxKind.soroban,
          xdr: signed,
        );
        report(SigningStep.confirming);
        if (_isDeposit) {
          final ledgerSeq = ref.read(syncProvider).value?.ledgerSeq ?? 0;
          await poolApi.confirmDeposit(amount: amount, ledgerSeq: ledgerSeq);
        } else {
          await poolApi.confirmWithdraw(amount);
        }
        await log.append(LocalActivityEvent(
          kind: _isDeposit ? 'pool_deposit' : 'pool_withdraw',
          amount: amount,
          assetCode: 'XLM',
          timestamp: DateTime.now(),
        ));
        ref.invalidate(activityItemsProvider);
        await ref.read(syncProvider.notifier).refresh();
        ref.invalidate(balancesProvider);
        if (mounted) _amountController.clear();
      });
    } on ApiException catch (e) {
      if (e.code == 'pool.withdraw_locked' && mounted) {
        setState(() => _lockError = ErrorCopy.forException(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pool = ref.watch(syncProvider).value?.pool;
    final balances = ref.watch(balancesProvider).value;

    return ListView(
      children: [
        Text(
          'Put your assets to work. Deposits are free anytime.',
          style: TextStyle(fontSize: 14, color: c.textSecondary),
        ),
        const SizedBox(height: 20),
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
              Text('Pool Balance', style: TextStyle(fontSize: 13, color: c.textSecondary)),
              const SizedBox(height: 8),
              RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.headlineMedium,
                  children: [
                    TextSpan(
                        text: pool == null
                            ? '—'
                            : '${AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(pool.amountRaw, pool.decimals))} '),
                    TextSpan(text: 'XLM', style: TextStyle(fontSize: 15, color: c.info)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                child: Row(
                  children: [
                    Icon(Icons.schedule, size: 14, color: c.muted),
                    const SizedBox(width: 8),
                    Text('Withdrawable in $_poolLockDays days', style: TextStyle(fontSize: 13, color: c.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            children: [
              Expanded(child: _tab('Deposit', _isDeposit, () => setState(() => _isDeposit = true))),
              Expanded(child: _tab('Withdraw', !_isDeposit, () => setState(() => _isDeposit = false))),
            ],
          ),
        ),
        const SizedBox(height: 20),
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
              Text(_isDeposit ? 'Deposit amount' : 'Withdraw amount',
                  style: TextStyle(fontSize: 13, color: c.textSecondary)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: Theme.of(context).textTheme.headlineMedium,
                      decoration: const InputDecoration(
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '0.00',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Text('XLM', style: TextStyle(fontSize: 15, color: c.info)),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                // Full width: without it the divider shrinks to the text.
                width: double.infinity,
                padding: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                child: Text(
                  'Available: ${balances?.native ?? '—'} XLM',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ),
            ],
          ),
        ),
        if (_lockError != null) ...[
          const SizedBox(height: 12),
          Text(_lockError!, style: TextStyle(color: c.negative, fontSize: 13)),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: AmountFormatter.isValidPositiveDecimal(_amountController.text) ? _submit : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: c.primary,
              foregroundColor: c.primaryText,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(_isDeposit ? 'Deposit' : 'Withdraw'),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text('Deposits reset the $_poolLockDays-day withdrawal timer.',
              style: TextStyle(fontSize: 12, color: c.muted)),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _tab(String label, bool selected, VoidCallback onTap) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? c.primary : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? c.primaryText : c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
