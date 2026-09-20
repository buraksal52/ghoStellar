import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Thrown by [ApiClient] whenever the backend's envelope is
/// `{"error":{"code","message","details"}}`. `code` is a dotted domain code
/// like `cheque.insufficient_balance` — see `error_copy.dart` for the
/// user-facing message map.
class ApiException implements Exception {
  ApiException({
    required this.code,
    required this.message,
    this.details,
    this.httpStatus,
  });

  final String code;
  final String message;
  final Object? details;
  final int? httpStatus;

  @override
  String toString() => 'ApiException($code: $message)';
}

/// Whether [e] means "never reached the network" rather than a real answer
/// from the server (a business error like `cheque.request_used`, which must
/// keep propagating unchanged). [ApiClient] normally wraps every
/// unreachable-server case as `ApiException(code: 'network.error')`, but
/// this also covers a raw [DioException]/[SocketException]/[TimeoutException]
/// escaping some other path (e.g. a future that timed out before ApiClient's
/// own wrapping ran), so every caller can classify "offline" the same way.
bool isNetworkFailure(Object e) =>
    (e is ApiException && e.code == 'network.error') ||
    e is SocketException ||
    e is TimeoutException ||
    (e is DioException && e.response == null);
