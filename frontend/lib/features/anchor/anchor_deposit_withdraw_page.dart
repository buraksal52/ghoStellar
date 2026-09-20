import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/api_error.dart';
import '../../core/errors/error_copy.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/amount_formatter.dart';
import '../../core/utils/anchor_status.dart';
import '../../data/api/models/anchor_models.dart';
import '../../data/api/models/sep6_models.dart';
import '../../data/api/models/tx_models.dart';
import '../../state/anchor_bookkeeping.dart';
import '../../state/anchor_providers.dart';
import '../../state/core_providers.dart';
import '../../state/signing_overlay_provider.dart';
import '../../state/sync_providers.dart';
import '../../state/wallet_providers.dart';

/// Fiat leg of the TR anchor. Deposits are wired in this currency; the
/// on-chain leg is `AnchorInfo.assetCode` (USDC).
const _fiatCode = 'TRY';

/// Stellar assets carry 7 decimals; the backend ledger stores raw units.
const _assetDecimals = anchorAssetDecimals;

const _pollInterval = Duration(seconds: 3);

/// ~2 minutes. The anchor keeps processing after we stop watching; this only
/// bounds how long the screen polls on its own.
const _maxPolls = 40;

/// The in-flight SEP-6 transaction this screen is following.
class _ActiveTx {
  _ActiveTx({required this.kind, required this.id, required this.amount, this.deposit, this.withdraw});

  /// 'deposit' | 'withdraw'
  final String kind;
  final String id;

  /// As entered: [_fiatCode] for a deposit, the on-chain asset for a withdraw.
  final String amount;
  final Sep6Deposit? deposit;
  final Sep6Withdraw? withdraw;

  Sep6Transaction? tx;

  /// Hash of the payment we submitted to the anchor (withdraw only).
  String? paymentHash;
  bool timedOut = false;

  bool get isDeposit => kind == 'deposit';
  String get status => tx?.status ?? 'pending_user_transfer_start';
  bool get isTerminal => tx?.isTerminal ?? false;
}

class AnchorDepositWithdrawPage extends ConsumerStatefulWidget {
  const AnchorDepositWithdrawPage({super.key});

  @override
  ConsumerState<AnchorDepositWithdrawPage> createState() => _AnchorDepositWithdrawPageState();
}

class _AnchorDepositWithdrawPageState extends ConsumerState<AnchorDepositWithdrawPage> {
  bool _isDeposit = true;
  final _amountController = TextEditingController();
  bool _busy = false;
  String? _error;

  _ActiveTx? _active;
  Timer? _pollTimer;
  bool _pollInFlight = false;
  int _pollCount = 0;
  bool _reported = false;
  bool _reconciled = false;

  @override
  void initState() {
    super.initState();
    // The ledger may already be cached (the activity feed watches it) or
    // arrive a moment later, once the anchor list has loaded.
    ref.listenManual(anchorTransactionsProvider, (_, next) {
      final txs = next.value;
      if (txs != null) _reconcile(txs);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _amountController.dispose();
    super.dispose();
  }

  // --- input ------------------------------------------------------------

  /// Deposits are wired in TRY (2 decimals); withdrawals send USDC (7).
  bool get _amountValid {
    final text = _amountController.text.trim();
    if (!AmountFormatter.isValidPositiveDecimal(text)) return false;
    return AmountFormatter.toRaw(text, _isDeposit ? 2 : _assetDecimals) != null;
  }

  // --- flow -------------------------------------------------------------

  Future<void> _start(AnchorInfo anchor) async {
    final amount = _amountController.text.trim();
    // Capture everything from `ref` up front: this method awaits, and the
    // user may leave the screen meanwhile.
    final api = ref.read(anchorApiProvider);
    final session = ref.read(anchorSessionProvider.notifier);
    final bookkeeping = ref.read(anchorBookkeepingProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isDeposit) {
        final dep = await session.withToken(
          anchor.id,
          (t) => api.sep6Deposit(anchor.id, t, assetCode: anchor.assetCode, amount: amount),
        );
        // The backend has its ledger row now, whether or not we are still here.
        bookkeeping.ledgerChanged();
        if (!mounted) return;
        _begin(anchor, _ActiveTx(kind: 'deposit', id: dep.id, amount: amount, deposit: dep));
      } else {
        final w = await session.withToken(
          anchor.id,
          (t) => api.sep6Withdraw(anchor.id, t, assetCode: anchor.assetCode, amount: amount),
        );
        bookkeeping.ledgerChanged();
        if (!mounted) return;
        final active = _ActiveTx(kind: 'withdraw', id: w.id, amount: amount, withdraw: w);
        final hash = await _payAnchor(anchor, active);
        // Failed payment: the overlay already showed why. The anchor's
        // pending withdraw simply expires unpaid.
        if (hash == null || !mounted) return;
        active.paymentHash = hash;
        _begin(anchor, active);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Transfers the backend still lists as in flight — started here or by the
  /// starter-funds flow, then left before they finished — are asked about once
  /// with the anchor and reported, so the activity feed does not show them as
  /// waiting forever. Best-effort: nothing here may surface an error or get in
  /// the way of the transfer this screen is following.
  Future<void> _reconcile(List<AnchorTransaction> txs) async {
    final anchor = ref.read(primaryAnchorProvider);
    // An empty ledger also comes back while the anchor list is still loading.
    if (_reconciled || anchor == null) return;
    _reconciled = true;

    // Newest first; a few is plenty and keeps the anchor calls bounded.
    final inFlight = txs.where((t) => !Sep6Transaction.terminalStatuses.contains(t.state)).take(5).toList();
    if (inFlight.isEmpty) return;

    final api = ref.read(anchorApiProvider);
    final session = ref.read(anchorSessionProvider.notifier);
    final bookkeeping = ref.read(anchorBookkeepingProvider);
    for (final row in inFlight) {
      if (!mounted) return;
      if (_active?.id == row.id) continue; // the poll loop owns this one
      try {
        final tx = await session.withToken(anchor.id, (t) => api.sep6Transaction(anchor.id, t, row.id));
        if (tx.status == row.state) continue;
        final isDeposit = row.kind == 'deposit';
        await bookkeeping.record(
          anchorId: anchor.id,
          txId: row.id,
          kind: row.kind,
          status: tx.status,
          completed: tx.isCompleted,
          // Same amounts `_finish` reports: what the anchor paid out for a
          // deposit, what it received for a withdraw.
          assetAmount: isDeposit ? tx.amountOut : tx.amountIn,
          stellarTxHash: tx.stellarTransactionId,
        );
      } catch (_) {
        // The anchor may not know this id any more, or the wallet may be
        // locked; the row just stays as it is until the next visit.
      }
    }
  }

  /// Signs and submits the payment that funds a withdraw. Returns the
  /// Stellar tx hash, or null when it failed (overlay shows the reason).
  Future<String?> _payAnchor(AnchorInfo anchor, _ActiveTx active) async {
    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) throw StateError('Wallet must be unlocked.');
    final api = ref.read(anchorApiProvider);
    final txApi = ref.read(txApiProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final w = active.withdraw!;

    return ref.read(signingOverlayProvider.notifier).run<String>((report) async {
      final xdr = await api.withdrawPaymentXdr(
        anchor.id,
        destination: w.accountId,
        memoType: w.memoType,
        memo: w.memo,
        amount: active.amount,
      );
      report(SigningStep.signing);
      final signed = signing.signTransactionXdr(xdr, keyPair);
      report(SigningStep.submitting);
      final res = await txApi.submit(
        idempotencyKey: const Uuid().v4(),
        purpose: 'anchor_withdraw',
        kind: TxKind.classic,
        xdr: signed,
      );
      return res.hash;
    });
  }

  void _begin(AnchorInfo anchor, _ActiveTx active) {
    setState(() {
      _active = active;
      _reported = false;
    });
    _startPolling(anchor.id);
  }

  void _startPolling(String anchorId) {
    _pollTimer?.cancel();
    _pollCount = 0;
    _pollTimer = Timer.periodic(_pollInterval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (++_pollCount > _maxPolls) {
        timer.cancel();
        setState(() => _active?.timedOut = true);
        return;
      }
      _pollOnce(anchorId);
    });
    _pollOnce(anchorId);
  }

  Future<void> _pollOnce(String anchorId) async {
    final active = _active;
    if (active == null || _pollInFlight) return;
    final api = ref.read(anchorApiProvider);
    final session = ref.read(anchorSessionProvider.notifier);
    _pollInFlight = true;
    try {
      final tx = await session.withToken(anchorId, (t) => api.sep6Transaction(anchorId, t, active.id));
      // The user may have moved on to a different transaction, or left.
      if (!mounted || !identical(_active, active)) return;
      setState(() => active.tx = tx);
      if (tx.isTerminal) {
        _pollTimer?.cancel();
        await _finish(anchorId, active, tx);
      }
    } catch (_) {
      // Transient (network, anchor hiccup, locked wallet): the next tick
      // retries. This runs from a timer, so nothing may escape it.
    } finally {
      _pollInFlight = false;
    }
  }

  /// Once the anchor reaches a final state: record it in the backend ledger,
  /// remember it locally, and refresh the balance.
  Future<void> _finish(String anchorId, _ActiveTx active, Sep6Transaction tx) async {
    if (_reported) return;
    _reported = true;
    await ref.read(anchorBookkeepingProvider).record(
          anchorId: anchorId,
          txId: active.id,
          kind: active.kind,
          status: tx.status,
          completed: tx.isCompleted,
          // The on-chain amount: what the anchor paid out (deposit) or what
          // we sent (withdraw).
          assetAmount: active.isDeposit ? tx.amountOut : active.amount,
          stellarTxHash: active.isDeposit ? tx.stellarTransactionId : active.paymentHash,
        );
  }

  /// Sandbox stand-in for the user's bank wire (the mock anchor's own
  /// endpoint). Progress then arrives through the normal polling.
  Future<void> _simulateWire(AnchorInfo anchor) async {
    final active = _active;
    if (active == null) return;
    final api = ref.read(anchorApiProvider);
    final session = ref.read(anchorSessionProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.withToken(
        anchor.id,
        (t) => api.sep6SimulateBankTransfer(anchor.id, t, active.id, amount: active.tx?.amountIn ?? active.amount),
      );
      if (mounted) await _pollOnce(anchor.id);
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reset() {
    _pollTimer?.cancel();
    setState(() {
      _active = null;
      _error = null;
      _amountController.clear();
    });
  }

  /// The anchor's own words when it refused (e.g. an amount outside its
  /// limits), else the generic copy for the error code.
  String _errorText(Object e) {
    if (e is ApiException) return ErrorCopy.forException(e);
    return 'Something went wrong. Please try again.';
  }

  // --- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // The bank ramp trades fiat for the app's asset via SEP-6/24, which needs
    // an issued asset — there's nothing to ramp into/out of for native XLM.
    // Reaching this page at all requires a link (app_drawer, home_page), and
    // those are hidden for a native deployment; this only guards a direct
    // deep link into it.
    final anchor = ref.watch(primaryAnchorProvider);
    final trustlineReady = ref.watch(syncProvider).value?.trustlineReady ?? false;
    final active = _active;

    if (anchor == null) {
      final failed = ref.watch(anchorsProvider).hasError;
      return Center(
        child: failed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Could not reach the bank service.', style: TextStyle(color: c.textSecondary)),
                  TextButton(onPressed: () => ref.invalidate(anchorsProvider), child: const Text('Retry')),
                ],
              )
            : const CircularProgressIndicator(),
      );
    }

    return ListView(
      children: [
        Text(
          'Move money between your bank and your Stellar wallet.',
          style: TextStyle(fontSize: 14, color: c.textSecondary),
        ),
        const SizedBox(height: 16),
        _modeToggle(enabled: active == null),
        if (!trustlineReady) ...[
          const SizedBox(height: 16),
          _trustlineBanner(),
        ],
        const SizedBox(height: 16),
        if (active == null) ..._form(anchor, trustlineReady) else _activeCard(anchor, active),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(fontSize: 13, color: c.negative)),
        ],
        const SizedBox(height: 24),
        _recent(anchor),
      ],
    );
  }

  List<Widget> _form(AnchorInfo anchor, bool trustlineReady) {
    final c = context.colors;
    final currency = _isDeposit ? _fiatCode : anchor.assetCode;
    return [
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
              _isDeposit ? 'Amount to deposit' : 'Amount to withdraw',
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
                const SizedBox(width: 12),
                Text(currency, style: TextStyle(fontSize: 15, color: c.info)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _isDeposit
                  ? 'You wire $_fiatCode from your bank; ${anchor.assetCode} arrives in your wallet.'
                  : 'You send ${anchor.assetCode} from your wallet; $_fiatCode is paid to your bank.',
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: (!_busy && trustlineReady && _amountValid) ? () => _start(anchor) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.primary,
            foregroundColor: c.primaryText,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_isDeposit ? 'Deposit' : 'Withdraw'),
        ),
      ),
    ];
  }

  Widget _activeCard(AnchorInfo anchor, _ActiveTx active) {
    final c = context.colors;
    final tx = active.tx;
    final failed = active.isTerminal && !(tx?.isCompleted ?? false);
    final waitingForWire = active.isDeposit && active.status == 'pending_user_transfer_start';

    return Container(
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
            active.isDeposit
                ? 'Deposit ${active.amount} $_fiatCode'
                : 'Withdraw ${active.amount} ${anchor.assetCode}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (!active.isTerminal && !active.timedOut)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(
                  failed || active.timedOut ? Icons.error_outline : Icons.check_circle_outline,
                  size: 18,
                  color: failed || active.timedOut ? c.negative : c.positive,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  active.timedOut && !active.isTerminal
                      ? 'Still processing — check Recent bank activity later'
                      : anchorStatusLabel(active.status, isDeposit: active.isDeposit),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (tx?.message != null && failed) ...[
            const SizedBox(height: 6),
            Text(tx!.message!, style: TextStyle(fontSize: 12, color: c.muted)),
          ],
          if (waitingForWire) ...[
            const SizedBox(height: 16),
            ..._instructions(active.deposit!),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _simulateWire(anchor),
                style: OutlinedButton.styleFrom(side: BorderSide(color: c.border), foregroundColor: c.text),
                child: const Text('Simulate bank transfer (sandbox)'),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The anchor is a testnet sandbox — no real money moves.',
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
          ],
          if (!active.isDeposit && active.withdraw?.message != null && !active.isTerminal) ...[
            const SizedBox(height: 12),
            Text(active.withdraw!.message!, style: TextStyle(fontSize: 12, height: 1.4, color: c.textSecondary)),
          ],
          if (active.isTerminal && (tx?.isCompleted ?? false)) ...[
            const SizedBox(height: 10),
            Text(
              active.isDeposit
                  ? 'You received ${tx?.amountOut ?? '—'} ${anchor.assetCode}.'
                  : '$_fiatCode is on its way to your bank.',
              style: TextStyle(fontSize: 13, color: c.textSecondary),
            ),
          ],
          if (active.isTerminal || active.timedOut) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _reset,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: c.primaryText,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _instructions(Sep6Deposit dep) {
    final c = context.colors;
    if (dep.instructions.isEmpty) {
      return [Text(dep.how, style: TextStyle(fontSize: 13, height: 1.4, color: c.textSecondary))];
    }
    return [
      Text('Send the transfer to', style: TextStyle(fontSize: 12, color: c.muted)),
      const SizedBox(height: 6),
      for (final i in dep.instructions)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(i.label, style: TextStyle(fontSize: 12, color: c.muted)),
                    Text(i.value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: Icon(Icons.copy_rounded, size: 18, color: c.textSecondary),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: i.value));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text('${i.label} copied')));
                },
              ),
            ],
          ),
        ),
    ];
  }

  Widget _recent(AnchorInfo anchor) {
    final c = context.colors;
    final txs = ref.watch(anchorTransactionsProvider).value ?? const <AnchorTransaction>[];
    if (txs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent bank activity', style: TextStyle(fontSize: 13, color: c.textSecondary)),
        const SizedBox(height: 8),
        for (final t in txs.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  t.kind == 'deposit' ? Icons.south_rounded : Icons.north_rounded,
                  size: 16,
                  color: c.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.kind == 'deposit' ? 'Deposit' : 'Withdraw', style: const TextStyle(fontSize: 14)),
                      Text(
                        anchorStatusLabel(t.state, isDeposit: t.kind == 'deposit'),
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ],
                  ),
                ),
                if (t.amount != null && t.decimals != null)
                  Text(
                    '${AmountFormatter.trimTrailingZeros(AmountFormatter.fromRaw(t.amount!, t.decimals!))} ${anchor.assetCode}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _trustlineBanner() {
    final c = context.colors;
    return Container(
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
    );
  }

  Widget _modeToggle({required bool enabled}) {
    final c = context.colors;
    Widget tab(String label, bool selected, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(color: selected ? c.primary : null, borderRadius: BorderRadius.circular(8)),
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
          ),
        );

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          tab('Deposit', _isDeposit, () => setState(() => _isDeposit = true)),
          tab('Withdraw', !_isDeposit, () => setState(() => _isDeposit = false)),
        ],
      ),
    );
  }
}
