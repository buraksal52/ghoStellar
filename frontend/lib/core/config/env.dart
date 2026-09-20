/// Build-time network + gateway constants.
///
/// Mirrors `deploy/example.env` in the backend so the app never guesses at
/// values the backend already fixes. The anchor's own asset code/issuer and
/// domain are NOT hardcoded here — they are per-deployment and independent
/// from [payAssetCode]/[payAssetIssuer] below, and must be fetched at
/// runtime from `GET /anchors`.
class Env {
  Env._();

  /// Fallback network passphrase, used only until the first `/sync` reply
  /// (`SyncResponse.networkPassphrase`) tells the app what the backend
  /// actually signs against — see `networkPassphraseProvider`. The backend's
  /// value always wins, so this only needs to be right for the brief window
  /// before login/sync completes; a stale or mismatched build-time default
  /// here can no longer make the app sign with the wrong network id.
  /// Override with `--dart-define=NETWORK_PASSPHRASE=...` when pointing a
  /// build at a non-default deployment.
  static const String networkPassphrase = String.fromEnvironment(
    'NETWORK_PASSPHRASE',
    defaultValue: 'Test SDF Network ; September 2015',
  );

  /// Override with `--dart-define=HORIZON_URL=...` to match a non-default
  /// deployment's `NETWORK_PASSPHRASE`.
  static const String horizonUrl = String.fromEnvironment(
    'HORIZON_URL',
    defaultValue: 'https://horizon-testnet.stellar.org',
  );

  /// The asset cheques are written in: native XLM by default (an empty issuer
  /// means native), matching the backend's `ASSET_CODE=native` /
  /// `ASSET_ISSUER=` (`backend/cmd/chequesvc/main.go`). The code is only the
  /// on-screen label for native. Override with
  /// `--dart-define=PAY_ASSET_CODE=... --dart-define=PAY_ASSET_ISSUER=...` to
  /// point a build at an issued-asset deployment (code **and** issuer must then
  /// match the backend's).
  static const String payAssetCode = String.fromEnvironment(
    'PAY_ASSET_CODE',
    defaultValue: 'XLM',
  );
  static const String payAssetIssuer = String.fromEnvironment(
    'PAY_ASSET_ISSUER',
    defaultValue: '',
  );

  /// Production backend. Override with `--dart-define=GATEWAY_BASE_URL=...`
  /// to use a local or alternative deployment.
  static const String gatewayBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
    defaultValue: 'https://ghostellar-production.up.railway.app',
  );

  /// Exposed (not just used internally by [networkLabel]) because it also
  /// gates testnet-only behavior that must never run against a real
  /// network — see `data/stellar/testnet_friendbot.dart`.
  static const String testnetPassphrase = 'Test SDF Network ; September 2015';
  static const String _publicPassphrase = 'Public Global Stellar Network ; September 2015';

  /// A short label for whichever network [passphrase] identifies — the one
  /// place a build pointed at the wrong network (SERVICE.md #20) would be
  /// visible to the user (see the Settings page).
  static String networkLabel(String passphrase) => switch (passphrase) {
        testnetPassphrase => 'Testnet',
        _publicPassphrase => 'Public',
        _ => 'Custom',
      };
}
