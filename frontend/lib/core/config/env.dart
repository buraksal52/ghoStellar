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

  /// APISIX edge gateway. Override with `--dart-define=GATEWAY_BASE_URL=...`
  /// for a device that can't reach `localhost` (e.g. a physical phone
  /// talking to a dev machine on the LAN).
  static const String gatewayBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
    defaultValue: 'http://localhost:9080',
  );
}
