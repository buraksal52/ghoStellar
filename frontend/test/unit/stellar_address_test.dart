import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/utils/stellar_address.dart';

void main() {
  const valid = 'GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7';

  group('StellarAddress.isValid', () {
    test('accepts a well-formed G... address', () {
      expect(StellarAddress.isValid(valid), isTrue);
    });

    test('trims surrounding whitespace', () {
      expect(StellarAddress.isValid('  $valid\n'), isTrue);
    });

    test('rejects null and empty input', () {
      expect(StellarAddress.isValid(null), isFalse);
      expect(StellarAddress.isValid(''), isFalse);
    });

    test('rejects a truncated address', () {
      expect(StellarAddress.isValid(valid.substring(0, 55)), isFalse);
    });

    test('rejects an over-long address', () {
      expect(StellarAddress.isValid('${valid}A'), isFalse);
    });

    test('rejects secret seeds and muxed addresses', () {
      expect(StellarAddress.isValid('S${valid.substring(1)}'), isFalse);
      expect(StellarAddress.isValid('M${valid.substring(1)}'), isFalse);
    });

    test('rejects lowercase', () {
      expect(StellarAddress.isValid(valid.toLowerCase()), isFalse);
    });

    test('rejects characters outside the base32 alphabet', () {
      for (final bad in ['0', '1', '8', '9']) {
        expect(StellarAddress.isValid('G$bad${valid.substring(2)}'), isFalse, reason: bad);
      }
    });

    test('rejects arbitrary QR payloads', () {
      expect(StellarAddress.isValid('https://example.com'), isFalse);
      expect(StellarAddress.isValid('web+stellar:pay?destination=$valid'), isFalse);
    });
  });
}
