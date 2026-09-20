import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/core/errors/error_copy.dart';
import 'package:ghostellar_app/data/api/api_client.dart';
import 'package:ghostellar_app/data/api/endpoints/tx_api.dart';
import 'package:ghostellar_app/data/api/models/tx_models.dart';

/// Answers `/tx/submit` with a canned `data` payload — `POST /tx/submit`
/// returns HTTP 200 even for a transaction the network rejected.
class _FakeClient extends Fake implements ApiClient {
  _FakeClient(this._data);
  final Map<String, dynamic> _data;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool noAuth = false,
    Map<String, String>? headers,
  }) async =>
      _data;
}

Future<SubmitResponse> _submit(Map<String, dynamic> data) => TxApi(_FakeClient(data)).submit(
      idempotencyKey: 'k',
      purpose: 'trustline',
      kind: TxKind.classic,
      xdr: 'AAAA',
    );

void main() {
  test('a successful submit is returned as-is', () async {
    final resp = await _submit({'hash': 'h', 'successful': true, 'replayed': false});
    expect(resp.hash, 'h');
    expect(resp.successful, isTrue);
  });

  test('a rejected submit (HTTP 200, successful:false) throws tx.submit_failed', () async {
    await expectLater(
      _submit({'hash': '', 'successful': false, 'resultCode': 'tx_failed', 'replayed': false}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'tx.submit_failed')
            .having((e) => e.message, 'message', 'tx_failed'),
      ),
    );
  });

  test('a rejected submit without a result code still throws', () async {
    await expectLater(
      _submit({'hash': '', 'successful': false, 'replayed': false}),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'tx.submit_failed')),
    );
  });

  test('PENDING (Soroban not yet confirmed) is not treated as a failure', () async {
    final resp = await _submit({'hash': 'h', 'successful': false, 'resultCode': 'PENDING', 'replayed': false});
    expect(resp.resultCode, 'PENDING');
  });

  test('tx.submit_failed carries user-facing copy for the Horizon result code', () {
    final funds = ErrorCopy.forException(
      ApiException(code: 'tx.submit_failed', message: 'tx_insufficient_balance'),
    );
    expect(funds, contains('XLM'));

    // An unknown result code falls back to the generic message.
    final unknown = ErrorCopy.forException(
      ApiException(code: 'tx.submit_failed', message: 'tx_something_new'),
    );
    expect(unknown, ErrorCopy.forCode('tx.submit_failed'));
  });
}
