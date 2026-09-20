import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/payments/payment_uri.dart';

void main() {
  const valid = 'GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7';
  const ulid = '01J8F2K9ABCDEFGHJKMNPQRSTV';

  group('PaymentRequest.tryParse', () {
    test('accepts a bare G... address (backward compatible)', () {
      final r = PaymentRequest.tryParse('  $valid\n');
      expect(r, isNotNull);
      expect(r!.destination, valid);
      expect(r.amount, isNull);
      expect(r.nonce, isNull);
    });

    test('round-trips a full request', () {
      final exp = DateTime.utc(2026, 9, 20, 12, 5);
      final uri = PaymentRequest(
        destination: valid,
        amount: '25.50',
        nonce: 'abc-123',
        expiresAt: exp,
      ).toUri();

      expect(uri, startsWith('web+stellar:pay?destination=$valid'));
      final r = PaymentRequest.tryParse(uri)!;
      expect(r.destination, valid);
      expect(r.amount, '25.50');
      expect(r.nonce, 'abc-123');
      expect(r.expiresAt, exp);
    });

    test('keeps the amount as an exact string', () {
      final r = PaymentRequest.tryParse('web+stellar:pay?destination=$valid&amount=0.1000001')!;
      expect(r.amount, '0.1000001');
    });

    test('a request without an amount lets the sender choose', () {
      final r = PaymentRequest.tryParse('web+stellar:pay?destination=$valid&asset_code=XLM')!;
      expect(r.amount, isNull);
    });

    test('rejects secret seeds and muxed destinations', () {
      expect(PaymentRequest.tryParse('S${valid.substring(1)}'), isNull);
      expect(PaymentRequest.tryParse('web+stellar:pay?destination=M${valid.substring(1)}'), isNull);
    });

    test('rejects foreign schemes and arbitrary payloads', () {
      expect(PaymentRequest.tryParse('https://example.com'), isNull);
      expect(PaymentRequest.tryParse('web+stellar:tx?xdr=AAAA'), isNull);
      expect(PaymentRequest.tryParse('ghostellar://pay?destination=$valid'), isNull);
      expect(PaymentRequest.tryParse(''), isNull);
      expect(PaymentRequest.tryParse(null), isNull);
    });

    test('rejects malformed, zero and negative amounts', () {
      for (final bad in ['abc', '0', '0.00', '-5', '1e3', '1,5', '.5']) {
        expect(
          PaymentRequest.tryParse('web+stellar:pay?destination=$valid&amount=$bad'),
          isNull,
          reason: bad,
        );
      }
    });

    test('rejects anything other than the native asset', () {
      expect(PaymentRequest.tryParse('web+stellar:pay?destination=$valid&asset_code=USDC'), isNull);
      expect(
        PaymentRequest.tryParse('web+stellar:pay?destination=$valid&asset_code=XLM&asset_issuer=$valid'),
        isNull,
      );
    });

    test('rejects a bad or oversized nonce and a bad expiry', () {
      expect(PaymentRequest.tryParse('web+stellar:pay?destination=$valid&x_req='), isNull);
      expect(
        PaymentRequest.tryParse('web+stellar:pay?destination=$valid&x_req=${'a' * 65}'),
        isNull,
      );
      expect(PaymentRequest.tryParse('web+stellar:pay?destination=$valid&x_exp=soon'), isNull);
      expect(PaymentRequest.tryParse('web+stellar:pay?destination=$valid&x_exp=-1'), isNull);
    });

    test('an expired request still parses; expiry is the caller\'s policy', () {
      final r = PaymentRequest.tryParse('web+stellar:pay?destination=$valid&x_exp=1000')!;
      expect(r.isExpiredAt(DateTime.utc(2026)), isTrue);
    });
  });

  group('PaymentRequest.isExpiredAt', () {
    final exp = DateTime.utc(2026, 9, 20, 12);

    test('is false before and true at/after the deadline', () {
      final r = PaymentRequest(destination: valid, expiresAt: exp);
      expect(r.isExpiredAt(exp.subtract(const Duration(seconds: 1))), isFalse);
      expect(r.isExpiredAt(exp), isTrue);
      expect(r.isExpiredAt(exp.add(const Duration(seconds: 1))), isTrue);
    });

    test('never expires without a deadline', () {
      expect(PaymentRequest(destination: valid).isExpiredAt(DateTime.utc(2100)), isFalse);
    });
  });

  group('ChequeHandoff', () {
    test('round-trips', () {
      final uri = const ChequeHandoff(
        chequeId: ulid,
        from: valid,
        amount: '25.50',
        nonce: 'abc-123',
      ).toUri();

      expect(uri, startsWith('ghostellar://cheque?id=$ulid'));
      final h = ChequeHandoff.tryParse(uri)!;
      expect(h.chequeId, ulid);
      expect(h.from, valid);
      expect(h.amount, '25.50');
      expect(h.nonce, 'abc-123');
    });

    test('rejects a chequeId that is not ULID-shaped (it becomes a URL path)', () {
      for (final bad in ['../auth/me', '$ulid/claim-xdr', 'short', '${ulid}X', '01J8F2K9ABCDEFGHJKMNPQRST?']) {
        expect(
          ChequeHandoff.tryParse('ghostellar://cheque?id=${Uri.encodeQueryComponent(bad)}&from=$valid'),
          isNull,
          reason: bad,
        );
      }
    });

    test('rejects a bad sender, a bad amount and foreign schemes', () {
      expect(ChequeHandoff.tryParse('ghostellar://cheque?id=$ulid&from=nope'), isNull);
      expect(ChequeHandoff.tryParse('ghostellar://cheque?id=$ulid&from=$valid&amount=-1'), isNull);
      expect(ChequeHandoff.tryParse('ghostellar://other?id=$ulid&from=$valid'), isNull);
      expect(ChequeHandoff.tryParse('web+stellar:pay?destination=$valid'), isNull);
      expect(ChequeHandoff.tryParse(null), isNull);
    });

    test('a payment request is not a handoff and vice versa', () {
      final handoff = const ChequeHandoff(chequeId: ulid, from: valid).toUri();
      expect(PaymentRequest.tryParse(handoff), isNull);
    });
  });
}
