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
