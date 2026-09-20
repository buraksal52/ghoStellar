import '../../../core/errors/api_error.dart';
import '../api_client.dart';
import '../models/tx_models.dart';

class TxApi {
  TxApi(this._client);
  final ApiClient _client;

  /// `POST /tx/submit` answers HTTP 200 even when the network rejected the
  /// transaction (`successful: false`). That is turned into an
  /// [ApiException] here so no caller can mistake a rejected submit for a
  /// success. `PENDING` (a Soroban tx not yet confirmed) is not a failure.
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
    final resp = SubmitResponse.fromJson(data);
    if (!resp.successful && resp.resultCode != 'PENDING') {
      throw ApiException(
        code: 'tx.submit_failed',
        message: resp.resultCode ?? 'transaction failed',
      );
    }
    return resp;
  }

  Future<Submission> lookup(String idempotencyKey) async {
    final data = await _client.get('/tx/$idempotencyKey');
    return Submission.fromJson(data);
  }
}
