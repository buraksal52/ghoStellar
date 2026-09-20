/// Money is never a double in this app — it crosses the API boundary as a
/// decimal string (`pkg/money.Amount` on the backend) and stays a string /
/// `BigInt`-backed value everywhere here too. These helpers only ever do
/// string/integer arithmetic, never float math, to avoid precision loss.
class AmountFormatter {
  AmountFormatter._();

  /// Formats a raw integer-string amount (as returned by `/sync`, e.g.
  /// `amountRaw` + `decimals`) into a human-readable decimal string.
  static String fromRaw(String amountRaw, int decimals) {
    final negative = amountRaw.startsWith('-');
    final digits = negative ? amountRaw.substring(1) : amountRaw;
    final padded = digits.padLeft(decimals + 1, '0');
    final whole = padded.substring(0, padded.length - decimals);
    final frac = decimals == 0 ? '' : padded.substring(padded.length - decimals);
    final trimmedWhole = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final withGrouping = _group(trimmedWhole);
    final value = frac.isEmpty ? withGrouping : '$withGrouping.$frac';
    return negative ? '-$value' : value;
  }

  /// Trims trailing fractional zeros for display (e.g. "50.0000000" ->
  /// "50"). Purely cosmetic string trimming — never touches the underlying
  /// value, so it's safe to apply only at the UI layer.
  static String trimTrailingZeros(String decimal) {
    if (!decimal.contains('.')) return decimal;
    var s = decimal.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// Inverse of [fromRaw] for a plain (ungrouped) decimal string: "1.5" with
  /// 7 decimals -> "15000000". Returns null when [decimal] is not a
  /// well-formed non-negative decimal or has more fractional digits than
  /// [decimals] — never rounds or truncates. String math only.
  static String? toRaw(String decimal, int decimals) {
    final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(decimal);
    if (m == null) return null;
    final frac = m.group(2) ?? '';
    if (frac.length > decimals) return null;
    final digits = (m.group(1)! + frac.padRight(decimals, '0')).replaceFirst(RegExp(r'^0+(?=\d)'), '');
    return digits;
  }

  static String _group(String whole) {
    final buffer = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buffer.write(',');
      buffer.write(whole[i]);
    }
    return buffer.toString();
  }

  /// Validates a user-entered decimal amount string (e.g. from a text
  /// field) is well-formed and positive, without ever parsing it to double.
  static bool isValidPositiveDecimal(String input) {
    if (input.isEmpty) return false;
    return RegExp(r'^\d+(\.\d+)?$').hasMatch(input) &&
        !RegExp(r'^0(\.0+)?$').hasMatch(input);
  }
}
