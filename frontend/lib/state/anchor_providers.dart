import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/models/anchor_models.dart';
import 'core_providers.dart';
import 'wallet_providers.dart';

final anchorsProvider = FutureProvider<List<AnchorInfo>>((ref) async {
  final api = ref.watch(anchorApiProvider);
  return api.list();
});

final primaryAnchorProvider = Provider<AnchorInfo?>((ref) {
  final anchors = ref.watch(anchorsProvider).value;
  return (anchors != null && anchors.isNotEmpty) ? anchors.first : null;
});

/// The anchor's own SEP-10 JWT — deliberately in-memory only, never
/// persisted, matching the backend's own "never touches the server" rule.
/// Every app restart re-triggers this login on first anchor-screen visit.
class AnchorSessionNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  Future<void> login(String anchorId) async {
    final anchorApi = ref.read(anchorApiProvider);
    final signing = ref.read(stellarSigningServiceProvider);
    final keyPair = ref.read(walletProvider).keyPair;
    if (keyPair == null) throw StateError('Wallet must be unlocked.');

    final challenge = await anchorApi.challenge(anchorId);
    final signed = signing.signTransactionXdr(challenge, keyPair);
    final token = await anchorApi.token(anchorId, signed);
    state = token;
  }

  void clear() => state = null;
}

final anchorSessionProvider = NotifierProvider<AnchorSessionNotifier, String?>(
  AnchorSessionNotifier.new,
);
