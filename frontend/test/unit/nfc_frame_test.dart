import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/nfc/nfc_frame.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
String _text(Uint8List? b) => b == null ? '<null>' : utf8.decode(b);

/// A payload of exactly [n] bytes.
Uint8List _payload(int n) => Uint8List.fromList(List.generate(n, (i) => 0x41 + (i % 26)));

void main() {
  late HceTagEmulator tag;
  late EmulatedTagLink link;

  setUp(() {
    tag = HceTagEmulator();
    link = EmulatedTagLink(tag);
  });

  group('reading the tag (GET)', () {
    test('a short payload arrives in one chunk', () async {
      tag.offer = _bytes('hello');

      final r = (await readerExchange(link))!;

      expect(_text(r.peerPayload), 'hello');
      expect(r.delivered, isFalse, reason: 'we offered nothing');
    });

    test('a long payload is reassembled across chunks, in order', () async {
      final payload = _payload(650); // 200 + 200 + 200 + 50
      tag.offer = payload;

      final r = (await readerExchange(link))!;

      expect(r.peerPayload, payload);
      // SELECT + 4 GETs
      expect(link.sent, hasLength(5));
    });

    test('chunk boundaries: 199, 200, 201 and the cap all round-trip', () async {
      for (final n in [1, 199, 200, 201, 400, 401, NfcProtocol.maxPayloadBytes]) {
        final t = HceTagEmulator()..offer = _payload(n);
        final r = (await readerExchange(EmulatedTagLink(t)))!;
        expect(r.peerPayload, _payload(n), reason: '$n bytes');
      }
    });

    test('a tag with nothing to offer is still a tag: peer is null', () async {
      tag.offer = null;
      tag.acceptWrites = true;

      final r = (await readerExchange(link, offer: _bytes('mine')))!;

      expect(r.peerPayload, isNull);
      expect(r.delivered, isTrue);
    });

    test('onRead fires exactly once, when the last chunk has been served', () async {
      var reads = 0;
      tag.offer = _payload(450);
      tag.onRead = () => reads++;

      // Serve chunks by hand and watch the callback.
      link = EmulatedTagLink(tag);
      await link.transceive(Uint8List.fromList([0x00, NfcProtocol.insSelect, 0x04, 0x00, 7, ...NfcProtocol.aid, 0x00]));
      await link.transceive(Uint8List.fromList([0x00, NfcProtocol.insGetData, 0, 0, 0]));
      expect(reads, 0);
      await link.transceive(Uint8List.fromList([0x00, NfcProtocol.insGetData, 0, 200, 0]));
      expect(reads, 0);
      await link.transceive(Uint8List.fromList([0x00, NfcProtocol.insGetData, 0x01, 0x90, 0])); // offset 400
      expect(reads, 1);
    });

    test('a payload over the size cap is refused, not read', () async {
      final tooBig = Uint8List(NfcProtocol.maxPayloadBytes + 1);
      tag.offer = tooBig;

      expect(await readerExchange(link), isNull);
    });

    test('a tag whose payload changes between chunks is refused', () async {
      tag.offer = _payload(450);
      final flaky = _FlakyLink(tag, mutateAfter: 3, mutate: () => tag.offer = _payload(300));

      expect(await readerExchange(flaky), isNull);
    });
  });

  group('writing to the tag (PUT)', () {
    test('a short payload is delivered in one command', () async {
      Uint8List? got;
      tag
        ..acceptWrites = true
        ..onWritten = (p) => got = p;

      final r = (await readerExchange(link, offer: _bytes('request')))!;

      expect(r.delivered, isTrue);
      expect(_text(got), 'request');
    });

    test('a long payload is chunked and delivered only once complete', () async {
      final payload = _payload(650);
      var deliveries = 0;
      Uint8List? got;
      tag
        ..acceptWrites = true
        ..onWritten = (p) {
          deliveries++;
          got = p;
        };

      final r = (await readerExchange(link, offer: payload))!;

      expect(r.delivered, isTrue);
      expect(deliveries, 1);
      expect(got, payload);
      // SELECT + GET(no data) + 4 PUTs
      expect(link.sent.where((a) => a[1] == NfcProtocol.insPutData), hasLength(4));
    });

    test('the first chunk carries the total length; later ones do not', () async {
      tag.acceptWrites = true;
      await readerExchange(link, offer: _payload(450));

      final puts = link.sent.where((a) => a[1] == NfcProtocol.insPutData).toList();
      expect(puts[0][4], 202, reason: '2-byte total + 200 payload bytes');
      expect((puts[0][5] << 8) | puts[0][6], 450);
      expect(puts[1][4], 200);
      expect(puts[2][4], 50);
      // Offsets count payload bytes already sent.
      expect((puts[1][2] << 8) | puts[1][3], 200);
      expect((puts[2][2] << 8) | puts[2][3], 400);
    });

    test('a tag that is not taking writes reports not-delivered', () async {
      tag
        ..offer = _bytes('theirs')
        ..acceptWrites = false;
      var written = false;
      tag.onWritten = (_) => written = true;

      final r = (await readerExchange(link, offer: _bytes('mine')))!;

      expect(_text(r.peerPayload), 'theirs', reason: 'reading still works');
      expect(r.delivered, isFalse);
      expect(written, isFalse);
    });

    test('an empty offer writes nothing', () async {
      tag.acceptWrites = true;
      await readerExchange(link, offer: Uint8List(0));
      expect(link.sent.where((a) => a[1] == NfcProtocol.insPutData), isEmpty);
    });

    test('an offer over the size cap is not sent', () async {
      tag.acceptWrites = true;
      final r = (await readerExchange(link, offer: Uint8List(NfcProtocol.maxPayloadBytes + 1)))!;
      expect(r.delivered, isFalse);
      expect(link.sent.where((a) => a[1] == NfcProtocol.insPutData), isEmpty);
    });

    test('a tap that breaks off mid-write delivers nothing', () async {
      var written = false;
      tag
        ..acceptWrites = true
        ..onWritten = (_) => written = true;

      // Send only the first of three chunks by hand, then "lose" the tag.
      await link.transceive(Uint8List.fromList([0x00, NfcProtocol.insSelect, 0x04, 0x00, 7, ...NfcProtocol.aid, 0x00]));
      final first = Uint8List.fromList([0x00, NfcProtocol.insPutData, 0, 0, 202, 0x02, 0x8A, ..._payload(200)]); // total 650
      expect(tag.process(first).last, 0x00);
      expect(written, isFalse);
    });

    test('a fresh SELECT discards a half-written payload', () async {
      var deliveries = <Uint8List>[];
      tag
        ..acceptWrites = true
        ..onWritten = deliveries.add;
      final aidSelect = Uint8List.fromList([0x00, NfcProtocol.insSelect, 0x04, 0x00, 7, ...NfcProtocol.aid, 0x00]);

      tag.process(aidSelect);
      tag.process(Uint8List.fromList([0x00, NfcProtocol.insPutData, 0, 0, 202, 0x02, 0x8A, ..._payload(200)]));
      // A new tap begins. The stale continuation must be refused, not stitched on.
      tag.process(aidSelect);
      final stale = tag.process(Uint8List.fromList([0x00, NfcProtocol.insPutData, 0, 200, 200, ..._payload(200)]));

      expect((stale[stale.length - 2] << 8) | stale[stale.length - 1], NfcProtocol.swWrongOffset);
      expect(deliveries, isEmpty);
    });

    test('an out-of-order chunk is refused', () async {
      tag.acceptWrites = true;
      final aidSelect = Uint8List.fromList([0x00, NfcProtocol.insSelect, 0x04, 0x00, 7, ...NfcProtocol.aid, 0x00]);
      tag.process(aidSelect);
      tag.process(Uint8List.fromList([0x00, NfcProtocol.insPutData, 0, 0, 202, 0x02, 0x8A, ..._payload(200)]));

      final skipped = tag.process(Uint8List.fromList([0x00, NfcProtocol.insPutData, 0x01, 0x90, 50, ..._payload(50)])); // offset 400, not 200

      expect((skipped[skipped.length - 2] << 8) | skipped[skipped.length - 1], NfcProtocol.swWrongOffset);
    });

    test('a declared length over the cap is refused before allocating', () async {
      tag.acceptWrites = true;
      final r = tag.process(Uint8List.fromList([0x00, NfcProtocol.insPutData, 0, 0, 4, 0xFF, 0xFF, 1, 2]));
      expect((r[r.length - 2] << 8) | r[r.length - 1], NfcProtocol.swWrongLength);
    });

    test('a chunk that overruns the declared total is refused', () async {
      tag.acceptWrites = true;
      tag.process(Uint8List.fromList([0x00, NfcProtocol.insSelect, 0x04, 0x00, 7, ...NfcProtocol.aid, 0x00]));
      // total 3 but 5 bytes follow
      final r = tag.process(Uint8List.fromList([0x00, NfcProtocol.insPutData, 0, 0, 7, 0x00, 0x03, 1, 2, 3, 4, 5]));
      expect((r[r.length - 2] << 8) | r[r.length - 1], NfcProtocol.swWrongLength);
    });
  });

  group('one tap, both directions', () {
    test('reads the tag and writes ours in the same exchange', () async {
      Uint8List? written;
      tag
        ..offer = _bytes('web+stellar:pay?destination=G…')
        ..acceptWrites = true
        ..onWritten = (p) => written = p;

      final r = (await readerExchange(link, offer: _bytes('ghostellar://cheque?id=…')))!;

      expect(_text(r.peerPayload), 'web+stellar:pay?destination=G…');
      expect(r.delivered, isTrue);
      expect(_text(written), 'ghostellar://cheque?id=…');
    });

    test('a real-size request and handoff both survive', () async {
      final request = _bytes(
        'web+stellar:pay?destination=GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7'
        '&amount=25.50&asset_code=USDC&asset_issuer=GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5'
        '&msg=ghoStellar&x_req=6f1e6c5e-2c3b-4a55-9d8e-0b6f2a1c9d10&x_exp=1758412800',
      );
      expect(request.length, greaterThan(240), reason: 'this is why the payload is chunked');
      tag.offer = request;

      final r = (await readerExchange(link))!;

      expect(r.peerPayload, request);
    });
  });

  group('not our tag', () {
    test('a wrong AID answers not-selected and the exchange yields null', () async {
      final r = await readerExchange(_RawLink((apdu) => Uint8List.fromList([0x6A, 0x82])));
      expect(r, isNull);
    });

    test('a truncated response is refused rather than crashing', () async {
      final r = await readerExchange(_RawLink((apdu) => Uint8List.fromList([0x90])));
      expect(r, isNull);
    });

    test('the tag ignores garbage APDUs', () {
      expect(tag.process(Uint8List.fromList([0x00])), [0x6D, 0x00]);
      expect(tag.process(Uint8List.fromList([0x00, 0x99, 0, 0, 0])), [0x6D, 0x00]);
    });

    test('SELECT for another AID is refused', () {
      final other = Uint8List.fromList([0x00, NfcProtocol.insSelect, 0x04, 0x00, 7, 1, 2, 3, 4, 5, 6, 7, 0x00]);
      expect(tag.process(other), [0x6D, 0x00]);
    });

    test('a truncated SELECT does not throw', () {
      expect(tag.process(Uint8List.fromList([0x00, NfcProtocol.insSelect, 0x04, 0x00, 7, 0xF0])), [0x6D, 0x00]);
    });
  });

  group('iOS: the OS already selected our AID', () {
    test('no SELECT is sent, and the exchange still works', () async {
      tag
        ..offer = _bytes('hello')
        ..acceptWrites = true;
      link = EmulatedTagLink(tag, alreadySelected: true);

      final r = (await readerExchange(link, offer: _bytes('mine')))!;

      expect(_text(r.peerPayload), 'hello');
      expect(r.delivered, isTrue);
      expect(link.sent.where((a) => a[1] == NfcProtocol.insSelect), isEmpty);
    });
  });
}

/// Runs every command through [handler] — for answers a well-behaved tag
/// would never give.
class _RawLink implements TagLink {
  _RawLink(this.handler);
  final Uint8List Function(Uint8List) handler;

  @override
  bool get alreadySelected => false;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async => handler(apdu);
}

/// Forwards to a real tag but lets a test change the tag after N commands.
class _FlakyLink implements TagLink {
  _FlakyLink(this.tag, {required this.mutateAfter, required this.mutate});
  final HceTagEmulator tag;
  final int mutateAfter;
  final void Function() mutate;
  int _n = 0;

  @override
  bool get alreadySelected => false;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    if (++_n == mutateAfter) mutate();
    return tag.process(apdu);
  }
}
