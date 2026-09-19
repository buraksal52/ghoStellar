import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/local_activity_log.dart';
import '../features/activity/widgets/activity_item.dart';
import 'sync_providers.dart';
import 'wallet_providers.dart';

final localActivityLogProvider = Provider((ref) => LocalActivityLog());

/// Merges `/sync` cheque history with this device's locally-recorded
/// pool/anchor events, newest first.
final activityItemsProvider = FutureProvider<List<ActivityItem>>((ref) async {
  final sync = ref.watch(syncProvider).value;
  final me = ref.watch(walletProvider).publicKey;
  final log = ref.watch(localActivityLogProvider);

  final items = <ActivityItem>[];
  if (sync != null && me != null) {
    items.addAll(sync.cheques.map((c) => ActivityItem.fromCheque(c, myAddress: me)));
  }
  final localEvents = await log.readAll();
  items.addAll(localEvents.map(ActivityItem.fromLocalEvent));

  items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return items;
});
