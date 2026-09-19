/// Cheap, format-only check for a Stellar account address (StrKey `G...`).
///
/// Deliberately skips the CRC16 checksum: this only guards against the wrong
/// thing being scanned or pasted (a URL, a secret seed, a muxed `M...`
/// address). Anything that slips through is still rejected by Horizon.
class StellarAddress {
  StellarAddress._();

  static final _pattern = RegExp(r'^G[A-Z2-7]{55}$');

  static bool isValid(String? raw) {
    if (raw == null) return false;
    return _pattern.hasMatch(raw.trim());
  }
}
