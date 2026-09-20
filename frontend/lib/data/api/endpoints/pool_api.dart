import '../api_client.dart';

class PoolApi {
  PoolApi(this._client);
  final ApiClient _client;

  Future<String> depositXdr(String amount) async {
    final data = await _client.post('/pool/deposit-xdr', body: {'amount': amount});
    return data['depositXdr'] as String;
  }

  Future<String> withdrawXdr(String amount) async {
    final data = await _client.post('/pool/withdraw-xdr', body: {'amount': amount});
    return data['withdrawXdr'] as String;
  }

  Future<void> confirmDeposit({required String amount, required int ledgerSeq}) =>
      _client.post(
        '/pool/confirm-deposit',
        body: {'amount': amount, 'ledgerSeq': ledgerSeq},
      );

  Future<void> confirmWithdraw({required String amount}) =>
      _client.post('/pool/confirm-withdraw', body: {'amount': amount});
}
