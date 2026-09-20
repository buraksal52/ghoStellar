import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/data/api/api_client.dart';

import '../support/fakes.dart';

class _Store extends FakeSecureWalletStore {
  _Store() : super(accessToken: 'tok');
  bool cleared = false;

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<void> clearTokens() async => cleared = true;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Map<String, dynamic> body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  late List<bool> signals;
  late _Store store;
  var sessionExpired = 0;

  ApiClient client(Future<ResponseBody> Function(RequestOptions) handler) {
    signals = [];
    store = _Store();
    sessionExpired = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://gateway.test'))..httpClientAdapter = _Adapter(handler);
    return ApiClient(
      walletStore: store,
      dio: dio,
      onReachability: signals.add,
      onSessionExpired: () => sessionExpired++,
    );
  }

  test('a normal response reports reachable', () async {
    final c = client((_) async => _json(200, {'data': {'ok': true}}));
    await c.get('/sync');
    expect(signals, [true]);
  });

  test('no response at all (connection failure) reports unreachable', () async {
    final c = client((o) async => throw DioException.connectionError(requestOptions: o, reason: 'no route'));
    await expectLater(c.get('/sync'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'network.error')));
    expect(signals, [false]);
  });

  test('a server error response still proves the network is up', () async {
    final c = client((_) async => _json(409, {'error': {'code': 'cheque.request_used', 'message': 'used'}}));
    await expectLater(
      c.post('/cheques', body: const {}),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'cheque.request_used')),
    );
    expect(signals, [true]);
    expect(sessionExpired, 0);
  });

  test('a 401 that cannot be refreshed reports reachable, clears the tokens and signals the expired session', () async {
    final c = client((_) async => _json(401, {'error': {'code': 'auth.invalid_token', 'message': 'expired'}}));
    await expectLater(c.get('/sync'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'auth.invalid_token')));
    expect(signals, [true]);
    expect(store.cleared, isTrue);
    expect(sessionExpired, 1);
  });
}
