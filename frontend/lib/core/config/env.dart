/// Testnet-only network + gateway constants for this build phase.
///
/// Mirrors `deploy/example.env` in the backend so the app never guesses at
/// values the backend already fixes. USDC asset code/issuer and the anchor
/// domain are NOT hardcoded here — they are per-deployment and must be
/// fetched at runtime from `GET /anchors`.
class Env {
  Env._();

  static const String networkPassphrase = 'Test SDF Network ; September 2015';
  static const String horizonUrl = 'https://horizon-testnet.stellar.org';
  static const String sorobanRpcUrl = 'https://soroban-testnet.stellar.org';

  /// The asset cheques are written in. Must match the backend's
  /// `ASSET_CODE` / `ASSET_ISSUER` (`backend/cmd/chequesvc/main.go`; default
  /// USDC issued by the testnet issuer below). Override with
  /// `--dart-define=PAY_ASSET_CODE=... --dart-define=PAY_ASSET_ISSUER=...`;
  /// an empty issuer means native XLM.
  ///
  /// UNVERIFIED against the live deployment — see docs/reference/platform/
  /// nfc-qr-temasli-odeme.md. If the deployed `ASSET_CODE` differs, these two
  /// constants are the only thing to change.
  static const String payAssetCode = String.fromEnvironment(
    'PAY_ASSET_CODE',
    defaultValue: 'USDC',
  );
  static const String payAssetIssuer = String.fromEnvironment(
    'PAY_ASSET_ISSUER',
    defaultValue: 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5',
  );

  /// Production backend. Override with `--dart-define=GATEWAY_BASE_URL=...`
  /// to use a local or alternative deployment.
  static const String gatewayBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
    defaultValue: 'https://ghostellar-production.up.railway.app',
  );
}
