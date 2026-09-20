import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/api/endpoints/anchor_api.dart';
import '../data/api/endpoints/auth_api.dart';
import '../data/api/endpoints/cheque_api.dart';
import '../data/api/endpoints/pool_api.dart';
import '../data/api/endpoints/sync_api.dart';
import '../data/api/endpoints/tx_api.dart';
import '../data/nfc/nfc_service.dart';
import '../data/stellar/horizon_read_service.dart';
import '../data/stellar/mnemonic_service.dart';
import '../data/stellar/stellar_signing_service.dart';
import '../data/storage/secure_wallet_store.dart';
import 'auth_providers.dart';
import 'connectivity_providers.dart';
import 'sync_providers.dart';

/// Every provider here is a stateless/singleton service wrapper — the
/// stateful, request-driven providers (auth session, sync data, signing
/// overlay) live in their own files under this directory.
final secureWalletStoreProvider = Provider((ref) => SecureWalletStore());

/// Wall clock behind an override point, so expiry logic (offline payment
/// handoffs, the offline-payment retry queue) is testable. Lives here
/// rather than in a feature-specific file so both `tap_providers.dart` and
/// `offline_providers.dart` can depend on it without an import cycle.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final apiClientProvider = Provider((ref) {
  return ApiClient(
    walletStore: ref.watch(secureWalletStoreProvider),
    onReachability: (online) {
      final notifier = ref.read(offlineModeProvider.notifier);
      online ? notifier.markOnline() : notifier.markOffline();
    },
    // The tokens are gone: drop authProvider's cached "already logged in" so
    // the next `ensureSession()` really logs in again.
    onSessionExpired: () => ref.invalidate(authProvider),
  );
});

final authApiProvider = Provider((ref) => AuthApi(ref.watch(apiClientProvider)));
final syncApiProvider = Provider((ref) => SyncApi(ref.watch(apiClientProvider)));
final chequeApiProvider = Provider((ref) => ChequeApi(ref.watch(apiClientProvider)));
final poolApiProvider = Provider((ref) => PoolApi(ref.watch(apiClientProvider)));
final txApiProvider = Provider((ref) => TxApi(ref.watch(apiClientProvider)));
final anchorApiProvider = Provider((ref) => AnchorApi(ref.watch(apiClientProvider)));

/// The network passphrase is learned from `/sync` — see
/// `networkPassphraseProvider`'s doc comment in sync_providers.dart.
final stellarSigningServiceProvider = Provider(
  (ref) => StellarSigningService(networkPassphrase: ref.watch(networkPassphraseProvider)),
);
final mnemonicServiceProvider = Provider((ref) => const MnemonicService());
final horizonReadServiceProvider = Provider((ref) => HorizonReadService());
final nfcServiceProvider = Provider((ref) => NfcService());
