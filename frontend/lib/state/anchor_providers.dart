import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_error.dart';
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

  /// Runs [call] with the anchor JWT, logging in first when there is none
  /// and once more when the anchor rejects an expired token. The JWT lives
  /// only in memory, so a long-idle session must recover without the user
  /// noticing. Retries exactly once — never loops.
  Future<T> withToken<T>(String anchorId, Future<T> Function(String token) call) async {
    Future<String> ensure() async {
      if (state == null) await login(anchorId);
      return state!;
    }

    try {
      return await call(await ensure());
    } on ApiException catch (e) {
      if (e.code != 'anchor.token_rejected') rethrow;
      clear();
      return await call(await ensure());
    }
  }
}

final anchorSessionProvider = NotifierProvider<AnchorSessionNotifier, String?>(
  AnchorSessionNotifier.new,
);

/// The backend's ledger of this wallet's anchor transactions, newest first.
final anchorTransactionsProvider = FutureProvider.autoDispose<List<AnchorTransaction>>((ref) async {
  final anchor = ref.watch(primaryAnchorProvider);
  if (anchor == null) return const [];
  return ref.watch(anchorApiProvider).transactions(anchor.id);
});
