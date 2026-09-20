import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, per wallet, that the automatic "starter funds" run has already
/// been offered once — so a failure can never turn into a retry loop on every
/// app start. The user retries by hand ("Get test funds").
class StarterFundsFlag {
  String _key(String publicKey) => 'ghoStellarStarterFundsOffered_$publicKey';

  Future<bool> wasOffered(String publicKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(publicKey)) ?? false;
  }

  Future<void> markOffered(String publicKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(publicKey), true);
  }
}
