import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/nfc/nfc_service.dart';

/// A stand-in for the two-phone NFC handshake. Lets a test decide when the
/// "other phone" reads our tag ([peerReads]) and what our reader session
/// sees ([deliver]).
class FakeNfc extends Fake implements NfcService {
  @override
  bool isEmulateSupported = true;
  @override
  bool isScanSupported = true;

  final broadcasts = <String>[];
  int stops = 0;
  int cancels = 0;
  final _reads = StreamController<void>.broadcast();
  final _scans = <Completer<String?>>[];

  @override
  Stream<void> get onPayloadRead => _reads.stream;

  void peerReads() => _reads.add(null);

  @override
  Future<void> startBroadcast(String payload) async => broadcasts.add(payload);

  @override
  Future<void> stopBroadcast() async => stops++;

  @override
  Future<String?> startScan({Duration timeout = const Duration(seconds: 30)}) {
    final c = Completer<String?>();
    _scans.add(c);
    return c.future;
  }

  int get scanCount => _scans.length;

  /// The peer's phone shows [payload] to our reader session.
  void deliver(String payload) {
    final open = _scans.where((c) => !c.isCompleted);
    if (open.isNotEmpty) open.last.complete(payload);
  }

  @override
  Future<void> cancelScan() async {
    cancels++;
    for (final c in _scans) {
      if (!c.isCompleted) c.complete(null);
    }
  }

  /// A reader session that ended without reading anything (timeout).
  void deliverNothing() {
    final open = _scans.where((c) => !c.isCompleted);
    if (open.isNotEmpty) open.last.complete(null);
  }
}
