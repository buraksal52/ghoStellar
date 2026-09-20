import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/api/endpoints/cheque_api.dart';
import 'package:ghostellar_app/data/api/endpoints/sync_api.dart';
import 'package:ghostellar_app/data/api/endpoints/tx_api.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';
import 'package:ghostellar_app/data/stellar/stellar_signing_service.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

export 'fake_nfc.dart';

const testSender = 'GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7';

class FakeSyncApi extends Fake implements SyncApi {
  List<Cheque> cheques = const [];
  int calls = 0;

  @override
  Future<SyncResponse> sync() async {
    calls++;
    return syncResponse(cheques);
  }
}

class FakeChequeApi extends Fake implements ChequeApi {
  Object? claimError;
  Object? createError;
  final claimed = <String>[];
  final acked = <String>[];
  int claimAttempts = 0;

  @override
  Future<String> claimXdr(String chequeId) async {
    claimAttempts++;
    if (claimError != null) throw claimError!;
    claimed.add(chequeId);
    return 'unsigned-$chequeId';
  }

  @override
  Future<void> confirmClaim(String chequeId, String txHash) async {}

  @override
  Future<void> ack(String chequeId) async => acked.add(chequeId);

  // Sender side.
  final created = <({String receiver, String amount, String? requestId})>[];
  final confirmedLocks = <String>[];
  final preauths = <String>[];

  @override
  Future<CreateChequeResult> create({
    required String receiver,
    required String amount,
    String? requestId,
  }) async {
    if (createError != null) throw createError!;
    created.add((receiver: receiver, amount: amount, requestId: requestId));
    return const CreateChequeResult(
      chequeId: '01J8F2K9ABCDEFGHJKMNPQRSTV',
      lockXdr: 'lock-xdr',
      preauthEntryXdr: 'entry-xdr',
      preauthPayloadHash: 'hash',
      expiresAt: 'x',
    );
  }

  @override
  Future<void> confirmLock(String chequeId, String txHash) async => confirmedLocks.add(chequeId);

  @override
  Future<void> preauth(String chequeId, String signedEntryXdr) async => preauths.add(chequeId);
}

class FakeTxApi extends Fake implements TxApi {
  @override
  Future<SubmitResponse> submit({
    required String idempotencyKey,
    required String purpose,
    required TxKind kind,
    required String xdr,
  }) async =>
      const SubmitResponse(hash: 'hash', successful: true, replayed: false);
}

class FakeSigning extends Fake implements StellarSigningService {
  @override
  String signTransactionXdr(String unsignedXdrBase64, KeyPair signer, {String? networkPassphrase}) =>
      'signed-$unsignedXdrBase64';

  @override
  String signAuthEntryXdr(String unsignedEntryXdrBase64, KeyPair signer) => 'signed-$unsignedEntryXdrBase64';
}

class UnlockedWallet extends WalletNotifier {
  UnlockedWallet(this.keyPair);
  final KeyPair keyPair;
  @override
  WalletState build() => WalletState(keyPair: keyPair);
}

class FakeSyncNotifier extends SyncNotifier {
  FakeSyncNotifier(this.initial);
  final List<Cheque> initial;
  int refreshes = 0;

  @override
  Future<SyncResponse> build() async => syncResponse(initial);

  @override
  Future<void> refresh() async => refreshes++;
}

SyncResponse syncResponse(List<Cheque> cheques) => SyncResponse(
      cheques: cheques,
      pool: const PoolDeposit(ownerAddress: 'x', amountRaw: '0', decimals: 7, updatedAt: 't'),
      trustlineReady: true,
      ledgerSeq: 1,
      serverTimeUnix: 1,
    );

Cheque testCheque(
  String id,
  String me, {
  String amountRaw = '255000000', // 25.5000000
  ChequeState state = ChequeState.havuzda,
  String? requestId,
  String? sender,
}) =>
    Cheque(
      id: id,
      senderAddress: sender ?? testSender,
      receiverAddress: me,
      requestId: requestId,
      tokenContract: 'C',
      amountRaw: amountRaw,
      decimals: 7,
      state: state,
      expiresAt: 'x',
      createdAt: 'x',
      updatedAt: 'x',
    );

