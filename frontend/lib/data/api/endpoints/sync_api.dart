import '../api_client.dart';
import '../models/cheque_models.dart';

class SyncApi {
  SyncApi(this._client);
  final ApiClient _client;

  Future<SyncResponse> sync() async {
    final data = await _client.get('/sync');
    return SyncResponse.fromJson(data);
  }
}
