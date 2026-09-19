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

/// Every provider here is a stateless/singleton service wrapper — the
/// stateful, request-driven providers (auth session, sync data, signing
/// overlay) live in their own files under this directory.
final secureWalletStoreProvider = Provider((ref) => SecureWalletStore());

final apiClientProvider = Provider((ref) {
  return ApiClient(walletStore: ref.watch(secureWalletStoreProvider));
});

final authApiProvider = Provider((ref) => AuthApi(ref.watch(apiClientProvider)));
final syncApiProvider = Provider((ref) => SyncApi(ref.watch(apiClientProvider)));
final chequeApiProvider = Provider((ref) => ChequeApi(ref.watch(apiClientProvider)));
final poolApiProvider = Provider((ref) => PoolApi(ref.watch(apiClientProvider)));
final txApiProvider = Provider((ref) => TxApi(ref.watch(apiClientProvider)));
final anchorApiProvider = Provider((ref) => AnchorApi(ref.watch(apiClientProvider)));

final stellarSigningServiceProvider =
    Provider((ref) => const StellarSigningService());
final mnemonicServiceProvider = Provider((ref) => const MnemonicService());
final horizonReadServiceProvider = Provider((ref) => HorizonReadService());
final nfcServiceProvider = Provider((ref) => NfcService());
