import '../api_client.dart';
import '../models/auth_models.dart';

class AuthApi {
  AuthApi(this._client);
  final ApiClient _client;

  /// Returns the unsigned SEP-10 challenge transaction XDR for [account].
  Future<({String transaction, String networkPassphrase})> challenge(
    String account,
  ) async {
    final data = await _client.get(
      '/auth/challenge',
      query: {'account': account},
      noAuth: true,
    );
    return (
      transaction: data['transaction'] as String,
      networkPassphrase: data['networkPassphrase'] as String,
    );
  }

  Future<TokenPair> token(String signedTransactionXdr) async {
    final data = await _client.post(
      '/auth/token',
      body: {'transaction': signedTransactionXdr},
      noAuth: true,
    );
    return TokenPair.fromJson(data);
  }

  Future<TokenPair> refresh(String refreshToken) async {
    final data = await _client.post(
      '/auth/refresh',
      body: {'refreshToken': refreshToken},
      noAuth: true,
    );
    return TokenPair.fromJson(data);
  }

  Future<AppUser> me() async {
    final data = await _client.get('/auth/me');
    return AppUser.fromJson(data);
  }
}
