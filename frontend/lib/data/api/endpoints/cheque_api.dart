import '../api_client.dart';
import '../models/cheque_models.dart';

class ChequeApi {
  ChequeApi(this._client);
  final ApiClient _client;

  Future<CreateChequeResult> create({
    required String receiver,
    required String amount,
  }) async {
    final data = await _client.post(
      '/cheques',
      body: {'receiver': receiver, 'amount': amount},
    );
    return CreateChequeResult.fromJson(data);
  }

  Future<void> preauth(String chequeId, String signedEntryXdr) => _client.post(
        '/cheques/$chequeId/preauth',
        body: {'signedEntryXdr': signedEntryXdr},
      );

  Future<String> claimXdr(String chequeId) async {
    final data = await _client.post('/cheques/$chequeId/claim-xdr');
    return data['claimXdr'] as String;
  }

  Future<String> forceCollectXdr(String chequeId) async {
    final data = await _client.post('/cheques/$chequeId/force-collect-xdr');
    return data['forceCollectXdr'] as String;
  }

  Future<void> confirmLock(String chequeId, String txHash) => _client.post(
        '/cheques/$chequeId/confirm-lock',
        body: {'txHash': txHash},
      );

  Future<void> confirmClaim(String chequeId, String txHash) => _client.post(
        '/cheques/$chequeId/confirm-claim',
        body: {'txHash': txHash},
      );

  Future<void> confirmForceCollect(
    String chequeId, {
    required String txHash,
    required bool collected,
  }) =>
      _client.post(
        '/cheques/$chequeId/confirm-force-collect',
        body: {'txHash': txHash, 'collected': collected},
      );

  Future<void> ack(String chequeId) => _client.post('/cheques/$chequeId/ack');
}
