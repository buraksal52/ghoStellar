import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/utils/amount_formatter.dart';

void main() {
  group('AmountFormatter', () {
    test('formats raw integer amounts with correct decimal placement', () {
      // fromRaw preserves full on-chain precision (never trims trailing
      // zeros) — trimming for display is a UI concern, done separately.
      expect(AmountFormatter.fromRaw('12487300000', 7), '1,248.7300000');
      expect(AmountFormatter.fromRaw('500000000', 7), '50.0000000');
      expect(AmountFormatter.fromRaw('1', 7), '0.0000001');
      expect(AmountFormatter.fromRaw('0', 7), '0.0000000');
      expect(AmountFormatter.fromRaw('-12500000', 7), '-1.2500000');
    });

    test('validates positive decimal input without ever using double parsing', () {
      expect(AmountFormatter.isValidPositiveDecimal('50.00'), isTrue);
      expect(AmountFormatter.isValidPositiveDecimal('0'), isFalse);
      expect(AmountFormatter.isValidPositiveDecimal('0.00'), isFalse);
      expect(AmountFormatter.isValidPositiveDecimal('-5'), isFalse);
      expect(AmountFormatter.isValidPositiveDecimal(''), isFalse);
      expect(AmountFormatter.isValidPositiveDecimal('abc'), isFalse);
    });
  });
}
