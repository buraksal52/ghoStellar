import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/nfc/nfc_service.dart';

/// A stand-in for the two-phone NFC exchange. It records what the app asks
/// the radio to do, and lets a test play "the other phone": [receive] is a
/// payload arriving (written to our tag, or read from theirs), [delivered]
/// is the other phone getting ours.
///
/// The defaults describe an Android phone (can be a tag, can read). Set
/// [canBeTag] false for an iPhone (reader only), both false for no NFC.
class FakeNfc extends Fake implements NfcService {
  @override
  bool canBeTag = true;
  @override
  bool canRead = true;

  @override
  bool get isAvailable => canBeTag || canRead;

  @override
  NfcRole get receiverRole => canBeTag ? NfcRole.tag : NfcRole.reader;

  @override
  NfcRole get senderRole => canBeTag ? NfcRole.auto : NfcRole.reader;

  /// Every `start` call, in order.
  final started = <({NfcRole role, String? offer})>[];

  /// Every payload we were asked to present/write — from `start` and
  /// `setOffer` alike, in order.
  final presented = <String>[];

  int stops = 0;

  /// Make `start` fail, as when NFC is switched off.
  Object? startError;

  final _peer = StreamController<String>.broadcast();
  final _delivered = StreamController<void>.broadcast();

  @override
  Stream<String> get onPeerPayload => _peer.stream;

  @override
  Stream<void> get onDelivered => _delivered.stream;

  /// The other phone hands us [payload].
  void receive(String payload) => _peer.add(payload);

  /// The other phone now has our offer.
  void delivered() => _delivered.add(null);

  @override
  Future<void> start({required NfcRole role, String? offer}) async {
    if (startError != null) throw startError!;
    started.add((role: role, offer: offer));
    if (offer != null) presented.add(offer);
  }

  @override
  Future<void> setOffer(String? offer) async {
    if (offer != null) presented.add(offer);
  }

  @override
  Future<void> stop() async => stops++;
}
