import '../api_client.dart';
import '../models/anchor_models.dart';
import '../models/sep6_models.dart';

class AnchorApi {
  AnchorApi(this._client);
  final ApiClient _client;

  Future<List<AnchorInfo>> list() async {
    final data = await _client.getRaw('/anchors');
    return (data as List).map((e) => AnchorInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<String> challenge(String anchorId) async {
    final data = await _client.get('/anchors/$anchorId/auth/challenge');
    return data['transaction'] as String;
  }

  Future<String> token(String anchorId, String signedTransactionXdr) async {
    final data = await _client.post('/anchors/$anchorId/auth/token', body: {'transaction': signedTransactionXdr});
    return data['token'] as String;
  }

  Future<({String id, String url})> deposit(String anchorId, String anchorToken) async {
    final data = await _client.post('/anchors/$anchorId/deposit', headers: {'X-Anchor-Token': anchorToken});
    return (id: data['id'] as String, url: data['url'] as String);
  }

  Future<({String id, String url})> withdraw(String anchorId, String anchorToken) async {
    final data = await _client.post('/anchors/$anchorId/withdraw', headers: {'X-Anchor-Token': anchorToken});
    return (id: data['id'] as String, url: data['url'] as String);
  }

  // --- SEP-6 (the flow the TR anchor actually publishes) -----------------
  // Every call needs the anchor's own SEP-10 JWT in X-Anchor-Token. The
  // backend injects `account` itself, so it is never sent from here.

  Map<String, String> _anchorAuth(String token) => {'X-Anchor-Token': token};

  /// Deposit: [amount] is in the FIAT currency (TRY) the user will wire.
  Future<Sep6Deposit> sep6Deposit(
    String anchorId,
    String anchorToken, {
    required String assetCode,
    required String amount,
  }) async {
    final data = await _client.get(
      '/anchors/$anchorId/sep6/deposit',
      query: {'asset_code': assetCode, 'amount': amount, 'type': 'bank_account'},
      headers: _anchorAuth(anchorToken),
    );
    return Sep6Deposit.fromJson(data);
  }

  /// Withdraw: [amount] is in the on-chain asset (USDC) the user will send.
  Future<Sep6Withdraw> sep6Withdraw(
    String anchorId,
    String anchorToken, {
    required String assetCode,
    required String amount,
  }) async {
    final data = await _client.get(
      '/anchors/$anchorId/sep6/withdraw',
      query: {'asset_code': assetCode, 'amount': amount, 'type': 'bank_account'},
      headers: _anchorAuth(anchorToken),
    );
    return Sep6Withdraw.fromJson(data);
  }

  Future<Sep6Transaction> sep6Transaction(String anchorId, String anchorToken, String txId) async {
    final data = await _client.get(
      '/anchors/$anchorId/sep6/transaction',
      query: {'id': txId},
      headers: _anchorAuth(anchorToken),
    );
    return Sep6Transaction.fromJson(data);
  }

  /// Sandbox-only: the mock anchor exposes this to stand in for the user's
  /// bank wire. A production anchor has no such endpoint.
  Future<void> sep6SimulateBankTransfer(
    String anchorId,
    String anchorToken,
    String txId, {
    required String amount,
  }) async {
    await _client.post(
      '/anchors/$anchorId/sep6/tx/$txId/simulate-bank-transfer',
      body: {'amount': amount},
      headers: _anchorAuth(anchorToken),
    );
  }

  /// Unsigned payment of [amount] to the anchor's withdraw account. The
  /// device signs it; `pay-tx-service` submits it.
  Future<String> withdrawPaymentXdr(
    String anchorId, {
    required String destination,
    required String memoType,
    required String memo,
    required String amount,
  }) async {
    final data = await _client.post(
      '/anchors/$anchorId/withdraw-payment-xdr',
      body: {'destination': destination, 'memoType': memoType, 'memo': memo, 'amount': amount},
    );
    return data['paymentXdr'] as String;
  }

  Future<void> reportTransaction(
    String anchorId,
    String txId, {
    required String kind,
    required String state,
    String? amount,
    int? decimals,
    String? stellarTxHash,
  }) => _client.post(
    '/anchors/$anchorId/transactions/$txId/report',
    body: {'kind': kind, 'state': state, 'amount': ?amount, 'decimals': ?decimals, 'stellarTxHash': ?stellarTxHash},
  );

  Future<List<AnchorTransaction>> transactions(String anchorId) async {
    final data = await _client.getRaw('/anchors/$anchorId/transactions');
    return (data as List).map((e) => AnchorTransaction.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<String> trustlineXdr(String anchorId) async {
    final data = await _client.post('/anchors/$anchorId/trustline-xdr');
    return data['trustlineXdr'] as String;
  }

  Future<void> trustlineConfirm(String anchorId, int ledgerSeq) =>
      _client.post('/anchors/$anchorId/trustline-confirm', body: {'ledgerSeq': ledgerSeq});
}
