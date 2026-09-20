import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/amount_formatter.dart';
import 'activity_providers.dart';
import 'anchor_providers.dart';
import 'core_providers.dart';
import 'home_providers.dart';
import 'sync_providers.dart';

/// Stellar assets carry 7 decimals; the backend ledger stores raw units.
const anchorAssetDecimals = 7;

final anchorBookkeepingProvider = Provider((ref) => AnchorBookkeeping(ref));

/// What happens once the anchor reaches a final state for a deposit or
/// withdrawal, shared by the Bank screen and the one-tap starter-funds flow:
/// record it in the backend ledger and refresh the balance. The activity feed
/// reads that ledger, so nothing is remembered locally.
class AnchorBookkeeping {
  AnchorBookkeeping(this._ref);
  final Ref _ref;

  /// The backend opens a ledger row the moment the anchor accepts a transfer,
  /// so the feeds that list it have to look again. Safe to call after the
  /// screen that started the transfer is gone.
  void ledgerChanged() {
    _ref.invalidate(anchorTransactionsProvider);
    _ref.invalidate(activityItemsProvider);
  }

  /// [assetAmount] is the on-chain amount: what the anchor paid out (deposit)
  /// or what we sent it (withdraw). Never throws — the anchor's own record is
  /// authoritative and the transfer has already happened.
  Future<void> record({
    required String anchorId,
    required String txId,
    required String kind,
    required String status,
    required bool completed,
    String? assetAmount,
    String? stellarTxHash,
  }) async {
    final api = _ref.read(anchorApiProvider);
    final sync = _ref.read(syncProvider.notifier);

    final raw = assetAmount == null ? null : AmountFormatter.toRaw(assetAmount, anchorAssetDecimals);
    try {
      await api.reportTransaction(
        anchorId,
        txId,
        kind: kind,
        state: status,
        amount: raw,
        decimals: raw == null ? null : anchorAssetDecimals,
        stellarTxHash: stellarTxHash,
      );
      if (completed && assetAmount != null) {
        await sync.refresh();
        // The deposit/withdrawal moved the anchor's own asset on chain; the
        // Horizon-backed balance card is not part of /sync.
        _ref.invalidate(balancesProvider);
      }
    } catch (_) {
      // Bookkeeping only.
    }
    _ref.invalidate(activityItemsProvider);
    _ref.invalidate(anchorTransactionsProvider);
  }
}
