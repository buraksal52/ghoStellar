import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/data/api/endpoints/anchor_api.dart';
import 'package:ghostellar_app/data/api/endpoints/auth_api.dart';
import 'package:ghostellar_app/data/api/endpoints/cheque_api.dart';
import 'package:ghostellar_app/data/api/endpoints/sync_api.dart';
import 'package:ghostellar_app/data/api/endpoints/tx_api.dart';
import 'package:ghostellar_app/data/api/models/anchor_models.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/data/api/models/sep6_models.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/data/stellar/stellar_signing_service.dart';
import 'package:ghostellar_app/state/anchor_providers.dart';
import 'package:ghostellar_app/state/starter_funds.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' hide AnchorTransaction;

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

  /// When set, [claimError] only applies to other cheque ids — this one
  /// always succeeds. Lets a test make one of several pending claims
  /// resolve while the rest keep failing.
  String? claimOnlyFor;

  /// Delays [claimXdr] by this long, to test overlapping calls.
  Duration? claimDelay;

  @override
  Future<String> claimXdr(String chequeId) async {
    claimAttempts++;
    final delay = claimDelay;
    if (delay != null) await Future<void>.delayed(delay);
    final only = claimOnlyFor;
    if (claimError != null && (only == null || chequeId != only)) throw claimError!;
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
  Object? submitError;
  final submitted = <({String idempotencyKey, String purpose, TxKind kind, String xdr})>[];

  @override
  Future<SubmitResponse> submit({
    required String idempotencyKey,
    required String purpose,
    required TxKind kind,
    required String xdr,
  }) async {
    submitted.add((idempotencyKey: idempotencyKey, purpose: purpose, kind: kind, xdr: xdr));
    if (submitError != null) throw submitError!;
    return const SubmitResponse(hash: 'hash', successful: true, replayed: false);
  }
}

class FakeSigning extends Fake implements StellarSigningService {
  /// The `networkPassphrase` passed to the most recent `signTransactionXdr`
  /// call (`null` if the caller took the default), so a test can assert a
  /// flow forwarded the right network — e.g. the anchor's own SEP-10
  /// passphrase (SERVICE.md #20).
  String? lastNetworkPassphrase;

  @override
  String signTransactionXdr(String unsignedXdrBase64, KeyPair signer, {String? networkPassphrase}) {
    lastNetworkPassphrase = networkPassphrase;
    return 'signed-$unsignedXdrBase64';
  }

  @override
  String signAuthEntryXdr(String unsignedEntryXdrBase64, KeyPair signer, {String? networkPassphrase}) =>
      'signed-$unsignedEntryXdrBase64';
}

class UnlockedWallet extends WalletNotifier {
  UnlockedWallet(this.keyPair);
  final KeyPair keyPair;
  @override
  WalletState build() => WalletState(keyPair: keyPair);
}

class FakeSyncNotifier extends SyncNotifier {
  FakeSyncNotifier(this.initial, {this.trustlineReady = true, this.poolAmountRaw = '0'});
  final List<Cheque> initial;
  final bool trustlineReady;
  final String poolAmountRaw;
  int refreshes = 0;

  @override
  Future<SyncResponse> build() async =>
      syncResponse(initial, trustlineReady: trustlineReady, poolAmountRaw: poolAmountRaw);

  @override
  Future<void> refresh() async => refreshes++;
}

SyncResponse syncResponse(List<Cheque> cheques, {bool trustlineReady = true, String poolAmountRaw = '0'}) =>
    SyncResponse(
      cheques: cheques,
      pool: PoolDeposit(ownerAddress: 'x', amountRaw: poolAmountRaw, decimals: 7, updatedAt: 't'),
      trustlineReady: trustlineReady,
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


/// Serves [responses] to successive `fetchBalances` calls (the last one
/// repeats), so a test can model "Horizon doesn't see the account yet, then
/// does" and count how often the app re-reads.
class FakeHorizonReadService extends Fake implements HorizonReadService {
  FakeHorizonReadService([List<AccountBalances>? responses])
      : responses = responses ?? [fundedBalances()];

  final List<AccountBalances> responses;
  int fetchCalls = 0;

  static AccountBalances fundedBalances({String native = '10000.0000000', Map<String, String> other = const {}}) =>
      AccountBalances(native: native, other: other);

  @override
  Future<AccountBalances> fetchBalances(String accountId) async {
    final i = fetchCalls < responses.length ? fetchCalls : responses.length - 1;
    fetchCalls++;
    return responses[i];
  }
}

class FakeAuthApi extends Fake implements AuthApi {
  bool fundResult = true;
  Object? fundError;
  int fundCalls = 0;

  /// Delays [fundTestnetXlm] by this long — lets a test catch it mid-flight
  /// (e.g. to prove a second tap while funding is in progress is ignored).
  Duration? fundDelay;

  @override
  Future<bool> fundTestnetXlm() async {
    fundCalls++;
    final delay = fundDelay;
    if (delay != null) await Future<void>.delayed(delay);
    if (fundError != null) throw fundError!;
    return fundResult;
  }
}


// ---- starter funds ("Get test funds") --------------------------------------

const testAnchor = AnchorInfo(
  id: 'default',
  domain: 'tr-mock-anchor.fly.dev',
  signingKey: 'GSIGNING',
  webAuthEndpoint: 'https://tr-mock-anchor.fly.dev/auth',
  assetCode: 'USDC',
  assetIssuer: 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5',
);

/// An anchor session that is already logged in.
class PresetAnchorSession extends AnchorSessionNotifier {
  @override
  String? build() => 'anchor-jwt';
}

/// The mock anchor as the starter-funds flow sees it: a trustline that opens
/// on confirm, and a TRY deposit whose polled status walks through [statuses]
/// (the last one repeats).
class FakeStarterAnchorApi extends Fake implements AnchorApi {
  /// Every call, in order: trustlineXdr, trustlineConfirm, deposit, simulate,
  /// transaction, report.
  final calls = <String>[];
  bool trustlineConfirmed = false;
  Object? depositError;
  List<String> statuses = ['completed'];
  String amountOut = '24.1000000';
  String? depositedAmount;
  Map<String, Object?>? report;
  int polls = 0;

  @override
  Future<String> trustlineXdr(String anchorId) async {
    calls.add('trustlineXdr');
    return 'trustline-xdr';
  }

  @override
  Future<void> trustlineConfirm(String anchorId) async {
    calls.add('trustlineConfirm');
    trustlineConfirmed = true;
  }

  @override
  Future<Sep6Deposit> sep6Deposit(String anchorId, String anchorToken,
      {required String assetCode, required String amount}) async {
    calls.add('deposit');
    if (depositError != null) throw depositError!;
    depositedAmount = amount;
    return const Sep6Deposit(id: 'sep_1', how: 'wire it', instructions: []);
  }

  @override
  Future<void> sep6SimulateBankTransfer(String anchorId, String anchorToken, String txId,
      {required String amount}) async {
    calls.add('simulate');
  }

  @override
  Future<Sep6Transaction> sep6Transaction(String anchorId, String anchorToken, String txId) async {
    calls.add('transaction');
    final status = statuses[polls < statuses.length ? polls : statuses.length - 1];
    polls++;
    return Sep6Transaction(
      id: txId,
      status: status,
      amountIn: '1000.00',
      amountOut: status == 'completed' ? amountOut : null,
      stellarTransactionId: status == 'completed' ? 'stellar-hash' : null,
    );
  }

  @override
  Future<void> reportTransaction(String anchorId, String txId,
      {required String kind, required String state, String? amount, int? decimals, String? stellarTxHash}) async {
    calls.add('report');
    report = {'kind': kind, 'state': state, 'amount': amount, 'decimals': decimals, 'hash': stellarTxHash};
  }

  @override
  Future<List<AnchorTransaction>> transactions(String anchorId) async => const [];
}

/// /sync whose `trustlineReady` follows the fake anchor: false until the
/// trustline has been confirmed, then true on the next refresh.
class TrustlineAwareSync extends FakeSyncNotifier {
  TrustlineAwareSync(this.anchor, {bool alreadyReady = false})
      : super(const [], trustlineReady: alreadyReady);
  final FakeStarterAnchorApi anchor;

  @override
  Future<void> refresh() async {
    refreshes++;
    state = AsyncData(syncResponse(const [], trustlineReady: trustlineReady || anchor.trustlineConfirmed));
  }
}

/// Stands in for the whole flow in widget tests that only care that a screen
/// starts it (and what the overlay then says).
class FakeStarterFunds extends Fake implements StarterFunds {
  int runs = 0;
  Object? error;
  String? usdcAdded = '24.1000000';
  Duration? delay;
  final labels = <String>[];

  @override
  Future<StarterFundsResult> run({void Function(String label)? progress}) async {
    runs++;
    const label = 'Preparing your wallet…';
    labels.add(label);
    progress?.call(label);
    final wait = delay;
    if (wait != null) await Future<void>.delayed(wait);
    if (error != null) throw error!;
    return StarterFundsResult(usdcAdded: usdcAdded);
  }
}

ApiException apiError(String code, [String message = 'm']) => ApiException(code: code, message: message);
