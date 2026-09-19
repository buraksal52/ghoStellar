import '../api_client.dart';
import '../models/tx_models.dart';

class TxApi {
  TxApi(this._client);
  final ApiClient _client;

  Future<SubmitResponse> submit({
    required String idempotencyKey,
    required String purpose,
    required TxKind kind,
    required String xdr,
  }) async {
    final data = await _client.post(
      '/tx/submit',
      body: {
        'idempotencyKey': idempotencyKey,
        'purpose': purpose,
        'kind': kind == TxKind.classic ? 'classic' : 'soroban',
        'xdr': xdr,
      },
    );
    return SubmitResponse.fromJson(data);
  }

  Future<Submission> lookup(String idempotencyKey) async {
    final data = await _client.get('/tx/$idempotencyKey');
    return Submission.fromJson(data);
  }
}
