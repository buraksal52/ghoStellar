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

  /// Production backend. Override with `--dart-define=GATEWAY_BASE_URL=...`
  /// to use a local or alternative deployment.
  static const String gatewayBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
    defaultValue: 'https://ghostellar-production.up.railway.app',
  );
}
