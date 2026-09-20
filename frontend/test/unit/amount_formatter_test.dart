import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/utils/amount_formatter.dart';

void main() {
  group('AmountFormatter.toRaw', () {
    test('scales whole and fractional amounts', () {
      expect(AmountFormatter.toRaw('5', 7), '50000000');
      expect(AmountFormatter.toRaw('1.5', 7), '15000000');
      expect(AmountFormatter.toRaw('0.0000001', 7), '1');
      expect(AmountFormatter.toRaw('1000.50', 2), '100050');
    });

    test('strips leading zeros but keeps a single zero', () {
      expect(AmountFormatter.toRaw('0', 7), '0');
      expect(AmountFormatter.toRaw('007', 0), '7');
      expect(AmountFormatter.toRaw('0.5', 7), '5000000');
    });

    test('rejects malformed or over-precise input instead of rounding', () {
      expect(AmountFormatter.toRaw('1.00000001', 7), isNull);
      expect(AmountFormatter.toRaw('-1', 7), isNull);
      expect(AmountFormatter.toRaw('1e3', 7), isNull);
      expect(AmountFormatter.toRaw('', 7), isNull);
      expect(AmountFormatter.toRaw('1,000', 7), isNull);
    });

    test('round-trips through fromRaw', () {
      final raw = AmountFormatter.toRaw('12.3456789', 7)!;
      expect(AmountFormatter.fromRaw(raw, 7), '12.3456789');
    });
  });
}
