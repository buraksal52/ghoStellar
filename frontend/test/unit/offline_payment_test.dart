import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/config/pay_asset.dart';
import 'package:ghostellar_app/core/payments/payment_uri.dart';
import 'package:ghostellar_app/data/stellar/offline_account_cache.dart';
import 'package:ghostellar_app/data/stellar/offline_payment_builder.dart';
import 'package:ghostellar_app/data/stellar/offline_payment_verifier.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

const _networkPassphrase = 'Test SDF Network ; September 2015';
final _network = Network(_networkPassphrase);
const _usdc = PayAsset(code: 'USDC', issuer: 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5');
const _xlm = PayAsset(code: 'XLM');
const _decimals = 7;

void main() {
  late KeyPair sender;
  late KeyPair receiver;
  late KeyPair impostor;
  late OfflineAccountSnapshot snapshot;
  const builder = OfflinePaymentBuilder();
  const verifier = OfflinePaymentVerifier();

  setUp(() {
    sender = KeyPair.random();
    receiver = KeyPair.random();
    impostor = KeyPair.random();
    snapshot = OfflineAccountSnapshot(
      accountId: sender.accountId,
      sequence: BigInt.from(41),
      availableRaw: '100000000', // 10 USDC
      decimals: _decimals,
      fetchedAt: DateTime.utc(2026, 9, 20),
    );
  });

  String build({
    KeyPair? signer,
    String amount = '5',
    String nonce = 'req-1',
    PayAsset asset = _usdc,
    DateTime? now,
  }) =>
      builder.buildAndSign(
        sender: signer ?? sender,
        snapshot: snapshot,
        destination: receiver.accountId,
        amount: amount,
        nonce: nonce,
        asset: asset,
        networkPassphrase: _networkPassphrase,
        now: now,
      );

  OfflineVerifyResult verify({
    required String xdr,
    String expectedDestination = '',
    String requestNonce = 'req-1',
    PayAsset asset = _usdc,
    String? minAmountRaw,
    DateTime? now,
  }) =>
      verifier.verify(
        signedXdr: xdr,
        expectedDestination: expectedDestination.isEmpty ? receiver.accountId : expectedDestination,
        requestNonce: requestNonce,
        asset: asset,
        decimals: _decimals,
        minAmountRaw: minAmountRaw,
        networkPassphrase: _networkPassphrase,
        now: now,
      );

  group('the happy path', () {
    test('a payment built for a request verifies against that same request', () {
      final xdr = build(amount: '5.5', nonce: 'req-42');

      final result = verify(xdr: xdr, requestNonce: 'req-42');

      expect(result.isValid, isTrue);
      expect(result.from, sender.accountId);
      expect(result.amount, '55000000');
      expect(result.decimals, _decimals);
    });

    test('the native asset works with no issuer anywhere', () {
      final xdr = build(asset: _xlm, amount: '3');
      expect(verify(xdr: xdr, asset: _xlm).isValid, isTrue);
    });

    test('an amount exactly at the requested minimum is accepted', () {
      final xdr = build(amount: '5');
      expect(verify(xdr: xdr, minAmountRaw: '50000000').isValid, isTrue);
    });

    test('an amount above the requested minimum is accepted (open request)', () {
      final xdr = build(amount: '9.9999999');
      expect(verify(xdr: xdr, minAmountRaw: '50000000').isValid, isTrue);
    });
  });

  group('the verifier trusts only the signed XDR, never the URI hints', () {
    test('a forged "from" in the handoff does not change what verify reports', () {
      final xdr = build();
      final forged = OfflinePayment(signedXdr: xdr, nonce: 'req-1', from: impostor.accountId, amount: '999');

      final result = verify(xdr: forged.signedXdr);

      expect(result.from, sender.accountId, reason: 'the real signer, not the forged hint');
      expect(result.amount, '50000000', reason: 'the real amount, not the forged hint');
    });
  });

  group('rejections', () {
    test('wrong destination', () {
      final xdr = build();
      final result = verify(xdr: xdr, expectedDestination: impostor.accountId);
      expect(result.failure, OfflineVerifyFailure.wrongDestination);
    });

    test('wrong asset code', () {
      final xdr = build(asset: _usdc);
      final result = verify(xdr: xdr, asset: PayAsset(code: 'EURC', issuer: _usdc.issuer));
      expect(result.failure, OfflineVerifyFailure.wrongAsset);
    });

    test('same code, different issuer is a different asset', () {
      final xdr = build(asset: _usdc);
      final result = verify(xdr: xdr, asset: PayAsset(code: 'USDC', issuer: impostor.accountId));
      expect(result.failure, OfflineVerifyFailure.wrongAsset);
    });

    test('native vs. issued mismatch either way', () {
      final nativeXdr = build(asset: _xlm);
      expect(verify(xdr: nativeXdr, asset: _usdc).failure, OfflineVerifyFailure.wrongAsset);

      final issuedXdr = build(asset: _usdc);
      expect(verify(xdr: issuedXdr, asset: _xlm).failure, OfflineVerifyFailure.wrongAsset);
    });

    test('below the requested amount', () {
      final xdr = build(amount: '4.9999999');
      expect(verify(xdr: xdr, minAmountRaw: '50000000').failure, OfflineVerifyFailure.amountTooLow);
    });

    test("a memo for someone else's request", () {
      final xdr = build(nonce: 'req-1');
      expect(verify(xdr: xdr, requestNonce: 'req-2').failure, OfflineVerifyFailure.memoDoesNotMatchRequest);
    });

    test('expired (now is past the time limit)', () {
      final built = DateTime.utc(2026, 9, 20, 12);
      final xdr = build(now: built);
      final result = verify(xdr: xdr, now: built.add(const Duration(hours: 25)));
      expect(result.failure, OfflineVerifyFailure.expired);
    });

    test('right at the limit counts as expired (maxTime is exclusive)', () {
      final built = DateTime.utc(2026, 9, 20, 12);
      final xdr = build(now: built);
      final result = verify(xdr: xdr, now: built.add(OfflinePaymentBuilder.validity));
      expect(result.failure, OfflineVerifyFailure.expired);
    });

    test('not yet expired, just before the limit', () {
      final built = DateTime.utc(2026, 9, 20, 12);
      final xdr = build(now: built);
      final result = verify(
        xdr: xdr,
        now: built.add(OfflinePaymentBuilder.validity - const Duration(seconds: 1)),
      );
      expect(result.isValid, isTrue);
    });

    test('signed by someone other than the account it claims to be from', () {
      // snapshot.accountId is still `sender`'s — only the signature is
      // swapped for `impostor`'s. A real attacker can't produce this
      // (they'd need sender's snapshot AND impostor's key for no reason),
      // but it's exactly the shape a bad/forged signature takes.
      final xdr = build(signer: impostor);
      final result = verify(xdr: xdr);
      expect(result.failure, OfflineVerifyFailure.senderDidNotSignIt);
    });

    test('garbage XDR', () {
      expect(verify(xdr: 'not-a-transaction').failure, OfflineVerifyFailure.malformedXdr);
    });

    test('a fee-bump envelope is not a plain payment', () {
      final inner = AbstractTransaction.fromEnvelopeXdrString(build()) as Transaction;
      final feeBump = (FeeBumpTransactionBuilder(inner)
            ..setBaseFee(OfflinePaymentBuilder.feeStroops * 2)
            ..setFeeAccount(sender.accountId))
          .build();
      feeBump.sign(sender, _network);
      final result = verify(xdr: feeBump.toEnvelopeXdrBase64());
      expect(result.failure, OfflineVerifyFailure.malformedXdr);
    });

    test('more than one operation is refused even if the first is a valid payment', () {
      final account = Account(sender.accountId, snapshot.sequence);
      final asset = Asset.createNonNativeAsset(_usdc.code, _usdc.issuer!);
      final tx = (TransactionBuilder(account)
            ..addOperation(PaymentOperationBuilder(receiver.accountId, asset, '5').build())
            ..addOperation(PaymentOperationBuilder(impostor.accountId, asset, '1').build()))
          .build();
      tx.sign(sender, _network);

      final result = verify(xdr: tx.toEnvelopeXdrBase64());
      expect(result.failure, OfflineVerifyFailure.notASingleClassicPayment);
    });

    test('a non-payment operation is refused', () {
      final account = Account(sender.accountId, snapshot.sequence);
      final tx = (TransactionBuilder(account)
            ..addOperation(BumpSequenceOperationBuilder(snapshot.sequence + BigInt.two).build()))
          .build();
      tx.sign(sender, _network);

      final result = verify(xdr: tx.toEnvelopeXdrBase64());
      expect(result.failure, OfflineVerifyFailure.notASingleClassicPayment);
    });

    test('no memo at all', () {
      final account = Account(sender.accountId, snapshot.sequence);
      final asset = Asset.createNonNativeAsset(_usdc.code, _usdc.issuer!);
      final tx = (TransactionBuilder(account)
            ..addOperation(PaymentOperationBuilder(receiver.accountId, asset, '5').build())
            ..addPreconditions(TransactionPreconditions()..timeBounds = TimeBounds(0, 9999999999)))
          .build();
      tx.sign(sender, _network);

      expect(verify(xdr: tx.toEnvelopeXdrBase64()).failure, OfflineVerifyFailure.memoDoesNotMatchRequest);
    });

    test('no time bounds at all', () {
      final account = Account(sender.accountId, snapshot.sequence);
      final asset = Asset.createNonNativeAsset(_usdc.code, _usdc.issuer!);
      final tx = (TransactionBuilder(account)
            ..addOperation(PaymentOperationBuilder(receiver.accountId, asset, '5').build())
            ..addMemo(MemoHash(Uint8List.fromList(sha256.convert(utf8.encode('req-1')).bytes))))
          .build();
      tx.sign(sender, _network);

      expect(verify(xdr: tx.toEnvelopeXdrBase64()).failure, OfflineVerifyFailure.noTimeLimit);
    });

    test('a time limit implausibly far in the future is refused', () {
      final built = DateTime.utc(2026, 9, 20, 12);
      final account = Account(sender.accountId, snapshot.sequence);
      final asset = Asset.createNonNativeAsset(_usdc.code, _usdc.issuer!);
      final farFuture = built.add(const Duration(days: 400)).millisecondsSinceEpoch ~/ 1000;
      final tx = (TransactionBuilder(account)
            ..addOperation(PaymentOperationBuilder(receiver.accountId, asset, '5').build())
            ..addMemo(MemoHash(Uint8List.fromList(sha256.convert(utf8.encode('req-1')).bytes)))
            ..addPreconditions(TransactionPreconditions()..timeBounds = TimeBounds(0, farFuture)))
          .build();
      tx.sign(sender, _network);

      expect(verify(xdr: tx.toEnvelopeXdrBase64(), now: built).failure, OfflineVerifyFailure.expiresTooFarInTheFuture);
    });

    test('a tampered amount after signing fails signature verification', () {
      final xdr = build(amount: '5');
      final tx = AbstractTransaction.fromEnvelopeXdrString(xdr) as Transaction;
      final asset = Asset.createNonNativeAsset(_usdc.code, _usdc.issuer!);
      final tampered = (TransactionBuilder(Account(sender.accountId, snapshot.sequence))
            ..addOperation(PaymentOperationBuilder(receiver.accountId, asset, '500').build())
            ..addMemo(tx.memo!)
            ..addPreconditions(tx.preconditions!))
          .build();
      tampered.signatures.addAll(tx.signatures); // reuse the original signature over different content

      final result = verify(xdr: tampered.toEnvelopeXdrBase64());
      expect(result.failure, OfflineVerifyFailure.senderDidNotSignIt);
    });
  });

  group('idempotency key material (the transaction hash)', () {
    test('is stable for the same signed XDR and differs for a different one', () {
      final xdr1 = build(nonce: 'req-1');
      final xdr2 = build(nonce: 'req-2');

      final h1a = (AbstractTransaction.fromEnvelopeXdrString(xdr1) as Transaction).hash(_network);
      final h1b = (AbstractTransaction.fromEnvelopeXdrString(xdr1) as Transaction).hash(_network);
      final h2 = (AbstractTransaction.fromEnvelopeXdrString(xdr2) as Transaction).hash(_network);

      expect(h1a, h1b);
      expect(h1a, isNot(h2));
    });
  });

  group('OfflinePayment (the handoff payload)', () {
    test('round-trips', () {
      final xdr = build();
      final uri = OfflinePayment(signedXdr: xdr, nonce: 'req-1', from: sender.accountId, amount: '5').toUri();

      final parsed = OfflinePayment.tryParse(uri)!;
      expect(parsed.signedXdr, xdr);
      expect(parsed.nonce, 'req-1');
      expect(parsed.from, sender.accountId);
      expect(parsed.amount, '5');
    });

    test('rejects a foreign scheme, a missing tx, and a missing request id', () {
      expect(OfflinePayment.tryParse('web+stellar:pay?destination=${receiver.accountId}'), isNull);
      expect(OfflinePayment.tryParse('ghostellar://offline?req=req-1'), isNull);
      expect(OfflinePayment.tryParse('ghostellar://offline?tx=abc'), isNull);
      expect(OfflinePayment.tryParse(null), isNull);
    });

    test('a bare cheque handoff is not an offline payment', () {
      final handoff = const ChequeHandoff(chequeId: '01J8F2K9ABCDEFGHJKMNPQRSTV', from: 'GX').toUri();
      expect(OfflinePayment.tryParse(handoff), isNull);
    });
  });
}
