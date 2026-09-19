import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../state/anchor_providers.dart';
import '../../state/core_providers.dart';
import '../../state/sync_providers.dart';
import 'anchor_webview_page.dart';

class AnchorDepositWithdrawPage extends ConsumerStatefulWidget {
  const AnchorDepositWithdrawPage({super.key});

  @override
  ConsumerState<AnchorDepositWithdrawPage> createState() => _AnchorDepositWithdrawPageState();
}

class _AnchorDepositWithdrawPageState extends ConsumerState<AnchorDepositWithdrawPage> {
  bool _isDeposit = true;
  final _amountController = TextEditingController();
  final _ibanController = TextEditingController();
  bool _loading = false;

  Future<void> _submit() async {
    final anchor = ref.read(primaryAnchorProvider);
    if (anchor == null) return;
    setState(() => _loading = true);
    try {
      var token = ref.read(anchorSessionProvider);
      if (token == null) {
        await ref.read(anchorSessionProvider.notifier).login(anchor.id);
        token = ref.read(anchorSessionProvider);
      }
      if (token == null) return;

      final anchorApi = ref.read(anchorApiProvider);
      final result = _isDeposit
          ? await anchorApi.deposit(anchor.id, token)
          : await anchorApi.withdraw(anchor.id, token);

      if (!mounted) return;
      await context.push(
        '/anchor/webview',
        extra: AnchorWebviewArgs(
          anchorId: anchor.id,
          txId: result.id,
          url: result.url,
          kind: _isDeposit ? 'deposit' : 'withdraw',
          amount: _amountController.text.trim().isEmpty ? null : _amountController.text.trim(),
          decimals: 7,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final trustlineReady = ref.watch(syncProvider).value?.trustlineReady ?? false;

    return ListView(
      children: [
        Text(
          'Move money between your bank and your Stellar wallet.',
          style: TextStyle(fontSize: 14, color: c.textSecondary),
        ),
        const SizedBox(height: 16),
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
        if (!trustlineReady) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: c.infoCard, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: c.info),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('USDC needs a one-time setup.', style: TextStyle(fontSize: 13, color: c.textSecondary)),
                ),
                TextButton(
                  onPressed: () => context.push('/anchor/trustline'),
                  child: Text('Set up →', style: TextStyle(color: c.info, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
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
              Text('Amount', style: TextStyle(fontSize: 13, color: c.textSecondary)),
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
                  Text('USDC', style: TextStyle(fontSize: 15, color: c.info)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
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
              Text(_isDeposit ? 'From bank' : 'To bank', style: TextStyle(fontSize: 13, color: c.textSecondary)),
              const SizedBox(height: 10),
              TextField(
                controller: _ibanController,
                decoration: const InputDecoration(hintText: 'IBAN / Account number'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: (!_loading && trustlineReady && AmountFormatter.isValidPositiveDecimal(_amountController.text))
                ? _submit
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: c.primary,
              foregroundColor: c.primaryText,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _loading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_isDeposit ? 'Deposit' : 'Withdraw'),
          ),
        ),
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
        decoration: BoxDecoration(color: selected ? c.primary : null, borderRadius: BorderRadius.circular(8)),
        child: Center(
          child: Text(
            label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? c.primaryText : c.textSecondary),
          ),
        ),
      ),
    );
  }
}
