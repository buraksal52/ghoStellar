import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/pay_asset.dart';
import '../../core/errors/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../data/api/models/cheque_models.dart';
import '../../data/api/models/tx_models.dart';
import '../../data/stellar/horizon_read_service.dart';
import '../../data/storage/local_activity_log.dart';
import '../../state/activity_providers.dart';
import '../../state/connectivity_providers.dart';
import '../../state/core_providers.dart';
import '../../state/home_providers.dart';
import '../../state/offline_providers.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/sync_providers.dart';
import '../../state/wallet_providers.dart';

/// A known reason the pool action can't work right now, with an optional
/// screen that fixes it.
class _Blocker {
  const _Blocker(this.message, [this.actionLabel, this.route]);
  final String message;
  final String? actionLabel;
  final String? route;
}

class PoolPage extends ConsumerStatefulWidget {
  const PoolPage({super.key});

  @override
  ConsumerState<PoolPage> createState() => _PoolPageState();
}

/// Mirrors the backend's `nativeReserveHeadroomRaw`
/// (`backend/services/cheque/service.go`) so the "Available" amount shown
/// here never offers more than the backend will actually accept: Stellar's
/// base reserve (1 XLM + 0.5/subentry) plus a fee buffer isn't spendable,
/// but Horizon's raw native balance includes it. Only applies to the
/// native asset — an issued asset carries no comparable reserve.
final _nativeReserveHeadroomRaw = BigInt.from(15000000); // 1.5 XLM, 7 decimals

class _PoolPageState extends ConsumerState<PoolPage> {
  bool _isDeposit = true;
  final _amountController = TextEditingController();

  String get _amount => _amountController.text.trim().replaceAll(',', '.');

  bool get _validAmount {
    final raw = AmountFormatter.toRaw(_amount, _decimals(ref.read(syncProvider).value?.pool));
    return raw != null && BigInt.parse(raw) > BigInt.zero;
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = _amount;
    if (!_validAmount) return;

    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) return;

    final poolApi = ref.read(poolApiProvider);
    final chainSubmit = ref.read(chainSubmitProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final overlay = ref.read(signingOverlayProvider.notifier);
    final log = ref.read(localActivityLogProvider);

    // Failures are caught by the overlay, which shows the ErrorCopy message.
    await overlay.run((report) async {
      final xdr = _isDeposit ? await poolApi.depositXdr(amount) : await poolApi.withdrawXdr(amount);
      report(SigningStep.signing);
      final signed = signing.signTransactionXdr(xdr, keyPair);
      report(SigningStep.submitting);
      final result = await chainSubmit.submit(
        idempotencyKey: const Uuid().v4(),
        purpose: _isDeposit ? 'pool_deposit' : 'pool_withdraw',
        kind: TxKind.soroban,
        xdr: signed,
      );
      if (!result.successful) {
        throw ApiException(
          code: result.resultCode == 'PENDING' ? 'tx.pending' : 'tx.submit_failed',
          message: result.resultCode ?? 'transaction failed',
        );
      }
      // The on-chain move has already happened: from here on nothing may
      // make the page say "failed", or leave the balance stale with the
      // amount still in the field — that invites a second tap, which builds a
      // new transaction under a new idempotency key and moves the money
      // twice. Refresh first (as SendPage does), and treat the backend
      // confirmation as best effort: its cache reconciles against the chain
      // on the next /sync anyway (`reconcilePoolWithChain`).
      ref.invalidate(balancesProvider);
      report(SigningStep.confirming);
      try {
        if (_isDeposit) {
          final ledgerSeq = ref.read(syncProvider).value?.ledgerSeq ?? 0;
          await poolApi.confirmDeposit(amount: amount, ledgerSeq: ledgerSeq);
        } else {
          await poolApi.confirmWithdraw(amount: amount);
        }
      } catch (_) {
        // Deliberately swallowed — see above.
      }
      await log.append(LocalActivityEvent(
        kind: _isDeposit ? 'pool_deposit' : 'pool_withdraw',
        amount: amount,
        timestamp: DateTime.now(),
      ));
      ref.invalidate(activityItemsProvider);
      await ref.read(syncProvider.notifier).refresh();
      ref.invalidate(balancesProvider);
      if (mounted) _amountController.clear();
    });
  }

  /// The largest deposit the backend will actually accept, in raw units:
  /// the account's balance minus Stellar's unspendable reserve for a native
  /// asset (`nativeReserveHeadroomRaw` in `backend/services/cheque/service.go`),
  /// or the plain balance for an issued asset (no comparable reserve). Shared
  /// by `_blocker` and the "Available" label so the UI never offers more
  /// than the backend will accept.
  BigInt? _depositLimitRaw(AccountBalances balances, int decimals) {
    final raw = AmountFormatter.toRaw(balances.payAsset, decimals);
    final rawLimit = raw == null ? null : BigInt.tryParse(raw);
    if (rawLimit == null || !balances.payAssetIsNative) return rawLimit;
    final afterReserve = rawLimit - _nativeReserveHeadroomRaw;
    return afterReserve.isNegative ? BigInt.zero : afterReserve;
  }

  /// Why deposit/withdraw can't work right now, if we already know — so the
  /// user reads a reason instead of a failed simulation. This is UX only; the
  /// contract and backend stay the real enforcement. Returns null while the
  /// inputs are still loading (never block on missing data).
  _Blocker? _blocker({
    required AccountBalances? balances,
    required bool? trustlineReady,
    required PoolDeposit? pool,
    required String amount,
  }) {
    // Deposit and withdraw are both Soroban calls built by the backend, so
    // neither can work offline — say so up front instead of letting the tap
    // sit through a connect timeout. Checked before the `balances == null`
    // bail-out: offline, the Horizon balance read fails, so it IS null.
    if (ref.watch(offlineModeProvider)) {
      return const _Blocker("The pool needs a connection — it isn't available offline. It will work again once you're back online.");
    }
    if (balances == null) return null;
    if (!balances.exists) {
      return const _Blocker('Your wallet isn\'t funded yet. Fund it from Settings first.', 'Open Settings', '/settings');
    }
    if (!balances.payAssetIsNative && trustlineReady == false) {
      return _Blocker('Set up ${PayAsset.configured.label} before using the pool.', 'Set up ${PayAsset.configured.label}', '/anchor/trustline');
    }

    final BigInt? limit;
    final String shortage;
    if (_isDeposit) {
      limit = _depositLimitRaw(balances, _decimals(pool));
      if (limit == BigInt.zero) {
        return balances.payAssetIsNative
            ? const _Blocker(
                'You have no funds yet. Get test funds from Settings first.',
                'Open Settings',
                '/settings',
              )
            : _Blocker(
                'You have no ${PayAsset.configured.label} yet. Add funds with a TRY bank deposit.',
                'Add funds',
                '/anchor',
              );
      }
      // `limit` (not the raw balance) is what's actually spendable — for a
      // native asset it already has the reserve taken out, so this must
      // name the same figure the "Available" line and the block above it
      // show, not the larger raw balance the person can't fully use anyway.
      shortage =
          'Not enough ${PayAsset.configured.label} — you have ${AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(limit.toString(), _decimals(pool)))}.';
    } else {
      // Unlike deposit, this is never allowed to fall through with a null
      // limit: a withdraw the backend will actually reject (no pool balance
      // loaded yet, or too little native XLM left to pay the withdraw
      // transaction's own fee — the fee-side twin of `_depositLimitRaw`'s
      // reserve headroom) must be caught here, or the person only finds out
      // from a bare simulation failure.
      if (pool == null) {
        return const _Blocker('Your pool balance is still loading — try again in a moment.');
      }
      if (!_hasFeeHeadroom(balances)) {
        return const _Blocker(
          'You need a little XLM in your wallet to cover the network fee.',
          'Open Settings',
          '/settings',
        );
      }
      limit = _withdrawLimitRaw(pool);
      if (limit == BigInt.zero) return const _Blocker('You have nothing in the pool to withdraw yet.');
      shortage = 'That is more than your pool balance.';
    }

    final typedRaw = AmountFormatter.toRaw(amount, _decimals(pool));
    final typed = typedRaw == null ? null : BigInt.tryParse(typedRaw);
    if (limit != null && typed != null && typed > limit) return _Blocker(shortage);
    return null;
  }

  /// The largest withdrawal the backend will actually accept, in raw units
  /// — the pool cache's own amount. `_blocker` never calls this before
  /// confirming `pool` is non-null; the null case is handled directly there.
  BigInt? _withdrawLimitRaw(PoolDeposit pool) => BigInt.tryParse(pool.amountRaw);

  /// Whether balances leaves enough native XLM spendable to cover a
  /// transaction's own network fee — mirrors the backend's
  /// `hasNativeFeeHeadroom` (`backend/services/cheque/service.go`). Only
  /// withdraw needs this as a stand-alone check: deposit's own headroom
  /// math (`_depositLimitRaw`) already nets the same reserve out of what it
  /// offers to deposit for the native asset, but a withdraw moves the pool
  /// asset while the fee is always paid in native XLM (`balances.native`)
  /// regardless of which asset is configured — so this must be checked even
  /// when the pool asset itself isn't native.
  bool _hasFeeHeadroom(AccountBalances balances) {
    final nativeRaw = AmountFormatter.toRaw(balances.native, 7);
    if (nativeRaw == null) return false;
    final native = BigInt.tryParse(nativeRaw);
    if (native == null) return false;
    return native - _nativeReserveHeadroomRaw >= BigInt.zero;
  }

  int _decimals(PoolDeposit? pool) => pool?.decimals ?? 7;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final synced = ref.watch(syncProvider).value;
    final pool = synced?.pool;
    final balances = ref.watch(balancesProvider).value;
    final amountText = _amount;
    final blocker = _blocker(
      balances: balances,
      trustlineReady: synced?.trustlineReady,
      pool: pool,
      amount: amountText,
    );
    final availableText = _isDeposit
        ? (balances == null
            ? '—'
            : AmountFormatter.trimTrailingZeros(
                AmountFormatter.fromRaw(_depositLimitRaw(balances, _decimals(pool))?.toString() ?? '0', _decimals(pool)),
              ))
        : (pool == null ? '—' : AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(pool.amountRaw, pool.decimals)));
    // A definite chain/cache mismatch is corrected server-side before /sync
    // serializes it (Sync's reconcilePoolWithChain) — chainVerified == false
    // only happens if that correction itself failed, so this is a rare,
    // soft "still checking" note rather than a routine state.
    final showUnverifiedNote = !_isDeposit && pool?.chainVerified == false;

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
                    TextSpan(text: PayAsset.configured.label, style: TextStyle(fontSize: 15, color: c.info)),
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
                    Text('Withdraw anytime when online', style: TextStyle(fontSize: 13, color: c.textSecondary)),
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
                      onTapOutside: (_) => FocusScope.of(context).unfocus(),
                    ),
                  ),
                  Text(PayAsset.configured.label, style: TextStyle(fontSize: 15, color: c.info)),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                // Full width: without it the divider shrinks to the text.
                width: double.infinity,
                padding: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                child: Text(
                  '${_isDeposit ? 'Available' : 'In pool'}: $availableText ${PayAsset.configured.label}',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ),
              if (showUnverifiedNote) ...[
                const SizedBox(height: 6),
                Text(
                  'Checking this balance against the network…',
                  style: TextStyle(fontSize: 11, color: c.muted, fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        ),
        if (blocker != null) ...[
          const SizedBox(height: 12),
          Text(blocker.message, style: TextStyle(color: c.negative, fontSize: 13)),
          if (blocker.actionLabel != null && blocker.route != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => context.go(blocker.route!),
                child: Text('${blocker.actionLabel!} →'),
              ),
            ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: blocker == null && _validAmount ? _submit : null,
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
          child: Text('Your pool balance is available to withdraw whenever you are online.',
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
