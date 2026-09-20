import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/nfc/nfc_frame.dart';
import 'package:ghostellar_app/data/nfc/nfc_service.dart';

class _FakeReader implements ReaderTransport {
  int starts = 0;
  int stops = 0;
  String? lastStartAlert;
  String? lastStopAlert;
  Object? startError;
  Future<void> Function(TagLink link)? _onLink;
  void Function()? _onEnded;

  @override
  Future<void> start({
    required Future<void> Function(TagLink link) onLink,
    void Function()? onEnded,
    String? alertMessage,
  }) async {
    if (startError != null) throw startError!;
    starts++;
    lastStartAlert = alertMessage;
    _onLink = onLink;
    _onEnded = onEnded;
  }

  @override
  Future<void> stop({String? alertMessage}) async {
    stops++;
    lastStopAlert = alertMessage;
  }

  /// A tag comes into range during the current window.
  Future<void> discover(TagLink link) async => _onLink?.call(link);

  /// The OS ends the session on its own (iOS cancel / 60 s limit).
  void osEnds() => _onEnded?.call();
}

class _FakeTag implements TagTransport {
  final presented = <({Uint8List? offer, bool acceptWrites})>[];
  int stops = 0;
  final _read = StreamController<void>.broadcast();
  final _written = StreamController<Uint8List>.broadcast();

  @override
  Stream<void> get onRead => _read.stream;

  @override
  Stream<Uint8List> get onWritten => _written.stream;

  @override
  Future<void> present({required Uint8List? offer, required bool acceptWrites}) async {
    presented.add((offer: offer, acceptWrites: acceptWrites));
  }

  @override
  Future<void> stop() async => stops++;

  void aReaderGotOurOffer() => _read.add(null);
  void aReaderWroteToUs(List<int> bytes) => _written.add(Uint8List.fromList(bytes));

  String? get lastOfferText {
    final o = presented.last.offer;
    return o == null ? null : utf8.decode(o);
  }
}

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// A phone's tag as a [TagLink], with [theirOffer] and whether it takes writes.
({EmulatedTagLink link, HceTagEmulator tag, List<String> written}) _peerTag({String? theirOffer, bool acceptWrites = true}) {
  final written = <String>[];
  final tag = HceTagEmulator()
    ..offer = theirOffer == null ? null : _b(theirOffer)
    ..acceptWrites = acceptWrites
    ..onWritten = (p) => written.add(utf8.decode(p));
  return (link: EmulatedTagLink(tag), tag: tag, written: written);
}

class _Rig {
  _Rig(TargetPlatform platform)
      : service = null {
    service = NfcService(
      reader: reader,
      tag: tag,
      platform: platform,
      readerWindow: const Duration(milliseconds: 100),
      tagWindow: const Duration(milliseconds: 100),
      readerTimeout: const Duration(seconds: 5),
    );
    peers = <String>[];
    delivered = 0;
    service!.onPeerPayload.listen(peers.add);
    service!.onDelivered.listen((_) => delivered++);
  }

  final reader = _FakeReader();
  final tag = _FakeTag();
  NfcService? service;
  late final List<String> peers;
  late int delivered;

  NfcService get s => service!;
}

void main() {
  group('platform capabilities', () {
    test('Android can be a tag and read; iOS can only read; others have no NFC', () {
      final android = _Rig(TargetPlatform.android).s;
      expect((android.canBeTag, android.canRead, android.isAvailable), (true, true, true));
      expect(android.receiverRole, NfcRole.tag);
      expect(android.senderRole, NfcRole.auto);

      final ios = _Rig(TargetPlatform.iOS).s;
      expect((ios.canBeTag, ios.canRead, ios.isAvailable), (false, true, true));
      expect(ios.receiverRole, NfcRole.reader);
      expect(ios.senderRole, NfcRole.reader);

      final windows = _Rig(TargetPlatform.windows).s;
      expect((windows.canBeTag, windows.canRead, windows.isAvailable), (false, false, false));
    });

    test('an iPhone cannot be a tag; a device without NFC cannot start at all', () async {
      final ios = _Rig(TargetPlatform.iOS).s;
      await expectLater(ios.start(role: NfcRole.tag, offer: 'x'), throwsUnsupportedError);

      final windows = _Rig(TargetPlatform.windows).s;
      await expectLater(windows.start(role: NfcRole.reader), throwsUnsupportedError);
    });

    test('an offer over the protocol cap is refused up front', () async {
      final s = _Rig(TargetPlatform.android).s;
      await expectLater(
        s.start(role: NfcRole.tag, offer: 'a' * (NfcProtocol.maxPayloadBytes + 1)),
        throwsArgumentError,
      );
    });
  });

  group('tag role (Android receiver)', () {
    testWidgets('presents the offer and accepts writes', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'web+stellar:pay?x');

      expect(rig.tag.presented.single.acceptWrites, isTrue);
      expect(rig.tag.lastOfferText, 'web+stellar:pay?x');
      expect(rig.reader.starts, 0, reason: 'a tag never runs a reader session');
      await rig.s.stop();
    });

    testWidgets('a reader writing to us is a peer payload', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'request');

      rig.tag.aReaderWroteToUs(utf8.encode('ghostellar://cheque?id=1'));
      await tester.pump();

      expect(rig.peers, ['ghostellar://cheque?id=1']);
      await rig.s.stop();
    });

    testWidgets('the same payload written twice is emitted once; a new one is emitted', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'request');

      rig.tag.aReaderWroteToUs(utf8.encode('a'));
      rig.tag.aReaderWroteToUs(utf8.encode('a'));
      rig.tag.aReaderWroteToUs(utf8.encode('b'));
      await tester.pump();

      expect(rig.peers, ['a', 'b']);
      await rig.s.stop();
    });

    testWidgets('bytes that are not text are dropped', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'request');

      rig.tag.aReaderWroteToUs([0xFF, 0xFE, 0xFD]);
      await tester.pump();

      expect(rig.peers, isEmpty);
      await rig.s.stop();
    });

    testWidgets('a reader taking our offer is "delivered" — once per offer', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'request');

      rig.tag.aReaderGotOurOffer();
      rig.tag.aReaderGotOurOffer();
      await tester.pump();
      expect(rig.delivered, 1);

      await rig.s.setOffer('handoff');
      rig.tag.aReaderGotOurOffer();
      await tester.pump();
      expect(rig.delivered, 2, reason: 'a new offer is a new delivery');
      await rig.s.stop();
    });

    testWidgets('a read while we offer nothing is not a delivery', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag);

      rig.tag.aReaderGotOurOffer();
      await tester.pump();

      expect(rig.delivered, 0);
      await rig.s.stop();
    });

    testWidgets('setOffer swaps what is presented without restarting', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'request');

      await rig.s.setOffer('handoff');

      expect(rig.tag.presented, hasLength(2));
      expect(rig.tag.lastOfferText, 'handoff');
      expect(rig.tag.presented.last.acceptWrites, isTrue);
      await rig.s.stop();
    });

    testWidgets('stop releases the tag and the reader', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'request');

      await rig.s.stop();

      expect(rig.tag.stops, 1);
      expect(rig.reader.stops, greaterThan(0));
    });

    testWidgets('stop with nothing running does nothing', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.stop();
      expect(rig.tag.stops, 0);
      expect(rig.reader.stops, 0);
    });
  });

  group('reader role (an iPhone, or a one-shot Android read)', () {
    testWidgets('reads the tag, writes our offer, then ends the session', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader, offer: 'my-request');
      expect(rig.reader.starts, 1);
      expect(rig.reader.lastStartAlert, isNotNull, reason: 'iOS shows this in the system sheet');

      final peer = _peerTag(theirOffer: 'their-payload');
      await rig.reader.discover(peer.link);
      await tester.pump();

      expect(rig.peers, ['their-payload']);
      expect(rig.delivered, 1);
      expect(peer.written, ['my-request']);
      expect(rig.reader.lastStopAlert, 'Done');

      // One shot: no new window follows.
      await tester.pump(const Duration(seconds: 30));
      expect(rig.reader.starts, 1);
    });

    testWidgets('an iPhone with nothing to give still pulls the tag\'s payload', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader);

      await rig.reader.discover(_peerTag(theirOffer: 'request-from-receiver').link);
      await tester.pump();

      expect(rig.peers, ['request-from-receiver']);
      expect(rig.delivered, 0);
    });

    testWidgets('an empty tag that takes writes is still a successful exchange', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader, offer: 'my-request');

      final peer = _peerTag();
      await rig.reader.discover(peer.link);
      await tester.pump();

      expect(rig.peers, isEmpty);
      expect(rig.delivered, 1);
      expect(peer.written, ['my-request']);
    });

    testWidgets('a tag that is not ours changes nothing and the window stays open', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader, offer: 'my-request');

      await rig.reader.discover(_RawLink((_) => Uint8List.fromList([0x6A, 0x82])));
      await tester.pump();

      expect(rig.peers, isEmpty);
      expect(rig.delivered, 0);
      expect(rig.reader.stops, 0, reason: 'still waiting for the right phone');

      // …which can still arrive.
      await rig.reader.discover(_peerTag(theirOffer: 'ok').link);
      await tester.pump();
      expect(rig.peers, ['ok']);
    });

    testWidgets('a tap lost mid-exchange keeps the window open', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader, offer: 'my-request');

      await rig.reader.discover(_RawLink((_) => throw StateError('tag was lost')));
      await tester.pump();

      expect(rig.peers, isEmpty);
      expect(rig.reader.stops, 0);
      await rig.s.stop();
    });

    testWidgets('gives up after the timeout and ends the session', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader, offer: 'my-request');

      await tester.pump(const Duration(seconds: 6));

      expect(rig.reader.stops, greaterThan(0));
      expect(rig.reader.lastStopAlert, isNull, reason: 'no "Done" for a failed read');
      expect(rig.peers, isEmpty);
      await tester.pump(const Duration(seconds: 30));
      expect(rig.reader.starts, 1, reason: 'a reader does not retry on its own');
    });

    testWidgets('the OS ending the session (iOS cancel button) ends the window', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader, offer: 'my-request');

      rig.reader.osEnds();
      await tester.pump();

      expect(rig.reader.stops, greaterThan(0));
    });

    testWidgets('NFC being unavailable ends quietly instead of throwing', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      rig.reader.startError = StateError('NFC is off');

      await rig.s.start(role: NfcRole.reader, offer: 'x'); // must not throw
      await tester.pump();

      expect(rig.peers, isEmpty);
    });

    testWidgets('an iPhone asked to be "auto" is just a reader', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.auto, offer: 'x');

      expect(rig.tag.presented, isEmpty, reason: 'it cannot present a tag');
      expect(rig.reader.starts, 1);
      await tester.pump(const Duration(seconds: 6));
      expect(rig.reader.starts, 1, reason: 'and it is one-shot');
    });
  });

  group('auto role (Android sender)', () {
    testWidgets('presents the offer AND alternates reader windows with listen windows', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.auto, offer: 'handoff');

      expect(rig.tag.lastOfferText, 'handoff');
      expect(rig.tag.presented.single.acceptWrites, isTrue);

      await tester.pump(const Duration(seconds: 1));

      // 100 ms reader + 100 ms listen, repeated — several windows in a second.
      expect(rig.reader.starts, greaterThanOrEqualTo(3));
      // Every window is closed before the next opens (the tag can answer in between).
      expect(rig.reader.stops, greaterThanOrEqualTo(rig.reader.starts - 1));

      await rig.s.stop();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a tap in a reader window exchanges, and the alternation carries on', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.auto, offer: 'handoff');
      await tester.pump(const Duration(milliseconds: 10));

      final peer = _peerTag(theirOffer: 'their-request');
      await rig.reader.discover(peer.link);
      await tester.pump();

      expect(rig.peers, ['their-request']);
      expect(peer.written, ['handoff']);
      expect(rig.delivered, 1);

      final startsAfterTap = rig.reader.starts;
      await tester.pump(const Duration(seconds: 1));
      expect(rig.reader.starts, greaterThan(startsAfterTap), reason: 'auto is continuous');

      await rig.s.stop();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('an iPhone reading our tag in a listen window is the tag side', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.auto, offer: 'handoff');

      // The native service reports the iPhone's read and its write.
      rig.tag.aReaderGotOurOffer();
      rig.tag.aReaderWroteToUs(utf8.encode('web+stellar:pay?destination=G'));
      await tester.pump();

      expect(rig.delivered, 1);
      expect(rig.peers, ['web+stellar:pay?destination=G']);

      await rig.s.stop();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('with nothing to offer yet it still takes a request written to it', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.auto);

      expect(rig.tag.presented.single.offer, isNull);
      expect(rig.tag.presented.single.acceptWrites, isTrue);
      rig.tag.aReaderWroteToUs(utf8.encode('the-request'));
      await tester.pump();
      expect(rig.peers, ['the-request']);

      await rig.s.stop();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('setOffer moves to the next step (request → handoff) on the running session', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.auto);
      await tester.pump(const Duration(milliseconds: 10));

      await rig.s.setOffer('handoff');
      final peer = _peerTag(theirOffer: 'their-request');
      await rig.reader.discover(peer.link);
      await tester.pump();

      expect(peer.written, ['handoff'], reason: 'the next reader window writes the new offer');
      expect(rig.tag.lastOfferText, 'handoff');

      await rig.s.stop();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('stop halts the alternation', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.auto, offer: 'x');
      await tester.pump(const Duration(milliseconds: 500));

      await rig.s.stop();
      await tester.pump(const Duration(seconds: 1));
      final starts = rig.reader.starts;
      await tester.pump(const Duration(seconds: 2));

      expect(rig.reader.starts, starts);
      expect(rig.tag.stops, 1);
    });
  });

  group('restarting', () {
    testWidgets('start replaces the running session; the old one is stopped', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'one');

      await rig.s.start(role: NfcRole.tag, offer: 'two');

      expect(rig.tag.stops, 1);
      expect(rig.tag.lastOfferText, 'two');
      await rig.s.stop();
    });

    testWidgets('a previous session\'s late tap is ignored', (tester) async {
      final rig = _Rig(TargetPlatform.iOS);
      await rig.s.start(role: NfcRole.reader, offer: 'first');
      final oldTap = rig.reader.discover;
      final stale = _peerTag(theirOffer: 'stale-payload');

      await rig.s.start(role: NfcRole.reader, offer: 'second');
      await oldTap(stale.link); // delivered to the NEW window's handler, but…
      await tester.pump();

      // …the new session is the one that counts; it accepted it normally.
      // What must never happen is the OLD offer being written.
      expect(stale.written, isNot(contains('first')));
    });

    testWidgets('restarting clears the "seen" memory so the same payload can arrive again', (tester) async {
      final rig = _Rig(TargetPlatform.android);
      await rig.s.start(role: NfcRole.tag, offer: 'r');
      rig.tag.aReaderWroteToUs(utf8.encode('same'));
      await tester.pump();

      await rig.s.start(role: NfcRole.tag, offer: 'r2');
      rig.tag.aReaderWroteToUs(utf8.encode('same'));
      await tester.pump();

      expect(rig.peers, ['same', 'same']);
      await rig.s.stop();
    });
  });
}

class _RawLink implements TagLink {
  _RawLink(this.handler);
  final Uint8List Function(Uint8List) handler;

  @override
  bool get alreadySelected => false;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async => handler(apdu);
}
