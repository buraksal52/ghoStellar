import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../../core/config/env.dart';

/// Pure crypto/XDR — no network calls here, fully unit-testable offline.
/// Every money-moving flow in the app funnels through this service: the
/// backend never receives anything but the outputs of these methods.
class StellarSigningService {
  /// [networkPassphrase] should be the live value from
  /// `networkPassphraseProvider` (learned from `/sync`), not a hardcoded
  /// default — see that provider's doc comment. Defaults to
  /// `Env.networkPassphrase` only so the constructor stays usable
  /// unconfigured (e.g. in tests, or before the first sync).
  const StellarSigningService({this.networkPassphrase = Env.networkPassphrase});

  final String networkPassphrase;

  Network get _network => Network(networkPassphrase);

  /// Restores a keypair from a raw Stellar secret seed (`S...`).
  KeyPair keypairFromSecretSeed(String secretSeed) =>
      KeyPair.fromSecretSeed(secretSeed);

  /// Signs an unsigned transaction envelope XDR (classic or Soroban — both
  /// are `Transaction`/`FeeBumpTransaction` envelopes at this layer) and
  /// returns the signed envelope, base64-encoded, ready for `/tx/submit`.
  String signTransactionXdr(
    String unsignedXdrBase64,
    KeyPair signer, {
    String? networkPassphrase,
  }) {
    final tx = AbstractTransaction.fromEnvelopeXdrString(unsignedXdrBase64);
    tx.sign(
      signer,
      networkPassphrase == null ? _network : Network(networkPassphrase),
    );
    return tx.toEnvelopeXdrBase64();
  }

  /// Signs a `SorobanAuthorizationEntry` (used for the cheque force-collect
  /// pre-authorization). The SDK reconstructs the exact CAP-46-11 preimage
  /// from the entry's own root invocation + credentials + network id, so no
  /// separately-supplied payload hash is needed on the client side.
  String signAuthEntryXdr(
    String unsignedEntryXdrBase64,
    KeyPair signer, {
    String? networkPassphrase,
  }) {
    final entry = SorobanAuthorizationEntry.fromBase64EncodedXdr(
      unsignedEntryXdrBase64,
    );
    entry.sign(signer, networkPassphrase == null ? _network : Network(networkPassphrase));
    return entry.toBase64EncodedXdrString();
  }
}
