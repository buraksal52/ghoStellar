import '../api_client.dart';
import '../models/anchor_models.dart';

class AnchorApi {
  AnchorApi(this._client);
  final ApiClient _client;

  Future<List<AnchorInfo>> list() async {
    final data = await _client.getRaw('/anchors');
    return (data as List)
        .map((e) => AnchorInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<String> challenge(String anchorId) async {
    final data = await _client.get('/anchors/$anchorId/auth/challenge');
    return data['transaction'] as String;
  }

  Future<String> token(String anchorId, String signedTransactionXdr) async {
    final data = await _client.post(
      '/anchors/$anchorId/auth/token',
      body: {'transaction': signedTransactionXdr},
    );
    return data['token'] as String;
  }

  Future<({String id, String url})> deposit(
    String anchorId,
    String anchorToken,
  ) async {
    final data = await _client.post(
      '/anchors/$anchorId/deposit',
      headers: {'X-Anchor-Token': anchorToken},
    );
    return (id: data['id'] as String, url: data['url'] as String);
  }

  Future<({String id, String url})> withdraw(
    String anchorId,
    String anchorToken,
  ) async {
    final data = await _client.post(
      '/anchors/$anchorId/withdraw',
      headers: {'X-Anchor-Token': anchorToken},
    );
    return (id: data['id'] as String, url: data['url'] as String);
  }

  Future<void> reportTransaction(
    String anchorId,
    String txId, {
    required String kind,
    required String state,
    String? amount,
    int? decimals,
    String? stellarTxHash,
  }) =>
      _client.post(
        '/anchors/$anchorId/transactions/$txId/report',
        body: {
          'kind': kind,
          'state': state,
          if (amount != null) 'amount': amount,
          if (decimals != null) 'decimals': decimals,
          if (stellarTxHash != null) 'stellarTxHash': stellarTxHash,
        },
      );

  Future<List<AnchorTransaction>> transactions(String anchorId) async {
    final data = await _client.getRaw('/anchors/$anchorId/transactions');
    return (data as List)
        .map((e) => AnchorTransaction.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<String> trustlineXdr(String anchorId) async {
    final data = await _client.post('/anchors/$anchorId/trustline-xdr');
    return data['trustlineXdr'] as String;
  }

  Future<void> trustlineConfirm(String anchorId, int ledgerSeq) =>
      _client.post(
        '/anchors/$anchorId/trustline-confirm',
        body: {'ledgerSeq': ledgerSeq},
      );
}
