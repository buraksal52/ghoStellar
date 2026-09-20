import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/local_activity_log.dart';
import '../features/activity/widgets/activity_item.dart';
import 'anchor_providers.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

final localActivityLogProvider = Provider((ref) => LocalActivityLog());

/// Merges `/sync` cheque history, the backend's bank (anchor) ledger and this
/// device's locally-recorded pool events, newest first.
final activityItemsProvider = FutureProvider<List<ActivityItem>>((ref) async {
  final sync = ref.watch(syncProvider).value;
  final me = ref.watch(walletProvider).publicKey;
  final log = ref.watch(localActivityLogProvider);
  // `.value`, not `.future`: an unreachable anchor service must leave the bank
  // rows empty rather than fail the whole feed — cheques still have to show.
  // This provider re-runs by itself once the ledger has loaded.
  final bank = ref.watch(anchorTransactionsProvider).value ?? const [];

  final items = <ActivityItem>[];
  if (sync != null && me != null) {
    items.addAll(sync.cheques.map((c) => ActivityItem.fromCheque(c, myAddress: me)));
  }
  items.addAll(bank.map(ActivityItem.fromAnchorTransaction));

  final localEvents = await log.readAll();
  // Older builds also logged completed bank transfers here. The ledger above
  // is the source of truth for those, so listing them again would double them.
  items.addAll(localEvents.where((e) => !e.kind.startsWith('anchor_')).map(ActivityItem.fromLocalEvent));

  items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return items;
});
