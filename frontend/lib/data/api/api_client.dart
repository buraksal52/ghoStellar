import 'package:dio/dio.dart';

import '../../core/config/env.dart';
import '../../core/errors/api_error.dart';
import '../storage/secure_wallet_store.dart';

/// Wraps every call to the backend gateway. Unwraps the
/// `{"data":...,"meta":...}` / `{"error":{...}}` envelope, attaches the
/// bearer token, and retries exactly once on a 401 by refreshing the token
/// pair — never loops.
class ApiClient {
  ApiClient({required SecureWalletStore walletStore, Dio? dio, this.onReachability, this.onSessionExpired})
      : _walletStore = walletStore,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: Env.gatewayBaseUrl,
              // Dio waits forever by default: one unanswered request would
              // leave a screen (or the signing overlay) spinning for good.
              // A timeout surfaces as `network.error` like any other outage.
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
            )) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (!options.extra.containsKey('noAuth')) {
            final token = await _walletStore.readAccessToken();
            if (token != null) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          final response = error.response;
          if (response?.statusCode == 401 &&
              !_isRetry(error.requestOptions) &&
              !error.requestOptions.extra.containsKey('noAuth')) {
            final refreshed = await _tryRefresh();
            if (refreshed) {
              try {
                final retried = await _retry(error.requestOptions);
                handler.resolve(retried);
                return;
              } catch (_) {
                // fall through to original error
              }
            } else {
              await _walletStore.clearTokens();
              onSessionExpired?.call();
            }
          }
          handler.next(error);
        },
      ),
    );
  }

  final Dio _dio;
  final SecureWalletStore _walletStore;

  /// Told `true` after any request actually reaches the gateway (whatever
  /// it answers with — even a business error means the network is up) and
  /// `false` whenever one comes back wrapped as `network.error`. Wired to
  /// `offlineModeProvider` in `core_providers.dart`; `null` in tests that
  /// construct `ApiClient` directly.
  final void Function(bool online)? onReachability;

  /// Called after a 401 whose token refresh also failed and the stored
  /// tokens were cleared — the session is gone until a fresh SEP-10 login.
  /// Wired to `authProvider` in `core_providers.dart`, so its cached "already
  /// authenticated" answer doesn't outlive the tokens it was derived from.
  final void Function()? onSessionExpired;

  bool _isRetry(RequestOptions options) => options.extra['retried'] == true;

  Future<bool> _tryRefresh() async {
    final refreshToken = await _walletStore.readRefreshToken();
    if (refreshToken == null) return false;
    try {
      final data = await post(
        '/auth/refresh',
        body: {'refreshToken': refreshToken},
        noAuth: true,
      );
      await _walletStore.saveTokens(
        accessToken: data['accessToken'] as String,
        refreshToken: data['refreshToken'] as String,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Response<dynamic>> _retry(RequestOptions options) {
    final newOptions = options.copyWith(extra: {...options.extra, 'retried': true});
    return _dio.fetch(newOptions);
  }

  /// Unwraps the envelope and returns whatever `data` holds — a `Map` for
  /// most endpoints, a `List` for the handful that return arrays directly
  /// (`GET /anchors`, `GET /anchors/{id}/transactions`), `null` for
  /// endpoints with no meaningful payload.
  dynamic _unwrap(Response<dynamic> response) {
    // A response of any shape (even an `{"error":...}` envelope) proves the
    // gateway is reachable.
    onReachability?.call(true);
    final body = response.data;
    if (body is! Map<String, dynamic>) {
      throw ApiException(
        code: 'client.bad_response',
        message: 'Unexpected response shape from server.',
        httpStatus: response.statusCode,
      );
    }
    if (body.containsKey('error')) {
      final err = body['error'] as Map<String, dynamic>;
      throw ApiException(
        code: err['code'] as String? ?? 'unknown',
        message: err['message'] as String? ?? 'Unknown error',
        details: err['details'],
        httpStatus: response.statusCode,
      );
    }
    return body['data'];
  }

  /// Use for endpoints whose `data` field is a JSON object.
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    bool noAuth = false,
    Map<String, String>? headers,
  }) async {
    final data = await getRaw(path, query: query, noAuth: noAuth, headers: headers);
    return (data as Map<String, dynamic>?) ?? const {};
  }

  /// Use for endpoints whose `data` field is a JSON array (or any shape).
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? query,
    bool noAuth = false,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.get(
        path,
        queryParameters: query,
        options: Options(extra: {if (noAuth) 'noAuth': true}, headers: headers),
      );
      return _unwrap(response);
    } on DioException catch (e) {
      final ex = _fromDioException(e);
      if (e.response == null) onReachability?.call(false);
      throw ex;
    }
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool noAuth = false,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.post(
        path,
        data: body,
        options: Options(extra: {if (noAuth) 'noAuth': true}, headers: headers),
      );
      return (_unwrap(response) as Map<String, dynamic>?) ?? const {};
    } on DioException catch (e) {
      final ex = _fromDioException(e);
      if (e.response == null) onReachability?.call(false);
      throw ex;
    }
  }

  ApiException _fromDioException(DioException e) {
    // Any HTTP response — even a 401/409/5xx — proves the gateway is
    // reachable; only "no response at all" means offline.
    if (e.response != null) onReachability?.call(true);
    final data = e.response?.data;
    if (data is Map<String, dynamic> && data.containsKey('error')) {
      final err = data['error'] as Map<String, dynamic>;
      return ApiException(
        code: err['code'] as String? ?? 'unknown',
        message: err['message'] as String? ?? 'Unknown error',
        details: err['details'],
        httpStatus: e.response?.statusCode,
      );
    }
    return ApiException(
      code: 'network.error',
      message: e.message ?? 'Network error',
      httpStatus: e.response?.statusCode,
    );
  }
}
