import 'dart:typed_data';

/// The ISO-DEP application protocol two ghoStellar phones speak over NFC.
///
/// One tap is a **symmetric exchange**: the reader phone *reads* the tag
/// phone's payload (GET) and *writes* its own (PUT), each an opaque byte
/// string. That is what lets an iPhone — which can only ever be the reader —
/// pay and receive: it pulls the Android's payload and pushes its own in the
/// same tap, so nobody has to "flip roles" mid-payment.
///
/// Payloads are longer than one short APDU can carry (an offline payment is
/// ~350 bytes), so both directions are chunked by byte offset:
///
///  * `SELECT AID` (`00 A4 04 00 07 F0476…`) — as before.
///  * `GET DATA`  `00 CA P1 P2 00`, P1P2 = offset into the payload →
///    `[total(2)] ‖ chunk(≤200)` + `90 00`, or `6A 82` when the tag offers
///    nothing.
///  * `PUT DATA`  `00 DA P1 P2 Lc data`, P1P2 = payload bytes already sent;
///    the first chunk (offset 0) is prefixed with `[total(2)]`. Each accepted
///    chunk answers `90 00`; the tag delivers the payload when the last one
///    lands. `69 85` means the tag isn't taking writes right now.
///
/// [HceTagEmulator] is the reference behaviour of the tag side — the Kotlin
/// `HceService` mirrors it line for line, and the tests run [readerExchange]
/// against it.
class NfcProtocol {
  NfcProtocol._();

  /// Custom, unregistered AID under the proprietary `F0` prefix (ISO/IEC
  /// 7816-5): this is our own app-to-app handshake, not a payment network AID.
  static const List<int> aid = [0xF0, 0x47, 0x68, 0x6F, 0x53, 0x74, 0x6C];
  static const String aidHex = 'F047686F53746C';

  static const int insSelect = 0xA4;
  static const int insGetData = 0xCA;
  static const int insPutData = 0xDA;

  /// Payload bytes per APDU. 200 + 2 length bytes + 2 status bytes stays
  /// well inside a short APDU (256).
  static const int chunkSize = 200;

  /// Refuse anything bigger: the length comes from the other phone.
  static const int maxPayloadBytes = 4096;

  static const int swOk = 0x9000;
  static const int swNoData = 0x6A82;
  static const int swWrongOffset = 0x6A86;
  static const int swWrongLength = 0x6700;
  static const int swNotAccepting = 0x6985;
  static const int swUnknown = 0x6D00;
}

/// One connected tag, from the reader's side. Android wraps `IsoDep`, iOS
/// wraps `NFCISO7816Tag`.
abstract interface class TagLink {
  /// True when the OS already selected our AID on discovery (iOS does, from
  /// the AIDs declared in Info.plist) — sending SELECT again is redundant.
  bool get alreadySelected;

  /// Sends one command APDU and returns `data ‖ SW1 SW2`.
  Future<Uint8List> transceive(Uint8List apdu);
}

/// What one tap achieved, from the reader's side.
class ExchangeResult {
  const ExchangeResult({this.peerPayload, this.delivered = false});

  /// The tag's payload, or null if it offered none.
  final Uint8List? peerPayload;

  /// Whether our payload was fully written to the tag.
  final bool delivered;

  bool get isEmpty => peerPayload == null && !delivered;
}

int _sw(Uint8List r) => r.length < 2 ? 0 : (r[r.length - 2] << 8) | r[r.length - 1];

Uint8List _selectApdu() => Uint8List.fromList([
      0x00, NfcProtocol.insSelect, 0x04, 0x00, NfcProtocol.aid.length, ...NfcProtocol.aid, 0x00, //
    ]);

Uint8List _getApdu(int offset) =>
    Uint8List.fromList([0x00, NfcProtocol.insGetData, (offset >> 8) & 0xFF, offset & 0xFF, 0x00]);

Uint8List _putApdu(int offset, Uint8List data) => Uint8List.fromList([
      0x00, NfcProtocol.insPutData, (offset >> 8) & 0xFF, offset & 0xFF, data.length, ...data, //
    ]);

/// Runs one tap as the reader: read the tag's payload and, if [offer] is set,
/// write ours. Returns null when this isn't a ghoStellar tag at all (wrong
/// AID, a protocol violation, or a payload over the size cap) — the caller
/// keeps polling. Transport errors (tag lost mid-tap) propagate as thrown
/// exceptions.
Future<ExchangeResult?> readerExchange(TagLink link, {Uint8List? offer}) async {
  if (!link.alreadySelected) {
    final r = await link.transceive(_selectApdu());
    if (_sw(r) != NfcProtocol.swOk) return null;
  }

  // ---- read the tag's payload ----
  Uint8List? peer;
  final first = await link.transceive(_getApdu(0));
  final firstSw = _sw(first);
  if (firstSw == NfcProtocol.swNoData) {
    peer = null;
  } else if (firstSw != NfcProtocol.swOk || first.length < 4) {
    return null;
  } else {
    final total = (first[0] << 8) | first[1];
    if (total == 0 || total > NfcProtocol.maxPayloadBytes) return null;

    final buffer = BytesBuilder(copy: false)..add(first.sublist(2, first.length - 2));
    while (buffer.length < total) {
      final r = await link.transceive(_getApdu(buffer.length));
      // The payload must not change under us, and every chunk must advance.
      if (_sw(r) != NfcProtocol.swOk || r.length < 5) return null;
      if (((r[0] << 8) | r[1]) != total) return null;
      buffer.add(r.sublist(2, r.length - 2));
    }
    if (buffer.length != total) return null;
    peer = buffer.toBytes();
  }

  // ---- write ours ----
  var delivered = false;
  if (offer != null && offer.isNotEmpty && offer.length <= NfcProtocol.maxPayloadBytes) {
    delivered = await _put(link, offer);
  }
  return ExchangeResult(peerPayload: peer, delivered: delivered);
}

Future<bool> _put(TagLink link, Uint8List payload) async {
  var offset = 0;
  while (offset < payload.length) {
    final end = (offset + NfcProtocol.chunkSize).clamp(0, payload.length);
    final chunk = payload.sublist(offset, end);
    final data = offset == 0
        ? Uint8List.fromList([(payload.length >> 8) & 0xFF, payload.length & 0xFF, ...chunk])
        : chunk;
    final r = await link.transceive(_putApdu(offset, data));
    if (_sw(r) != NfcProtocol.swOk) return false;
    offset = end;
  }
  return true;
}

/// The tag side of the protocol as pure Dart. The real one is
/// `android/.../nfc/HceService.kt`, which must behave identically; this
/// exists so [readerExchange] is tested against the protocol itself rather
/// than against itself.
class HceTagEmulator {
  /// What we present to a reader (null = nothing).
  Uint8List? offer;

  /// Whether a reader may write to us right now.
  bool acceptWrites = false;

  /// Fired once, when a reader has been served the last chunk of [offer].
  void Function()? onRead;

  /// Fired when a reader has written a complete payload.
  void Function(Uint8List payload)? onWritten;

  Uint8List? _incoming;
  int _incomingTotal = 0;
  int _incomingLength = 0;

  Uint8List _sw(int sw, [List<int> data = const []]) =>
      Uint8List.fromList([...data, (sw >> 8) & 0xFF, sw & 0xFF]);

  Uint8List process(Uint8List apdu) {
    if (apdu.length < 5) return _sw(NfcProtocol.swUnknown);

    switch (apdu[1]) {
      case NfcProtocol.insSelect:
        final aidLen = apdu[4];
        if (apdu.length < 5 + aidLen) return _sw(NfcProtocol.swUnknown);
        final aid = apdu.sublist(5, 5 + aidLen);
        if (aid.length != NfcProtocol.aid.length) return _sw(NfcProtocol.swUnknown);
        for (var i = 0; i < aid.length; i++) {
          if (aid[i] != NfcProtocol.aid[i]) return _sw(NfcProtocol.swUnknown);
        }
        _incoming = null; // a fresh tap starts a fresh write
        return _sw(NfcProtocol.swOk);

      case NfcProtocol.insGetData:
        final payload = offer;
        if (payload == null) return _sw(NfcProtocol.swNoData);
        final offset = (apdu[2] << 8) | apdu[3];
        if (offset > payload.length) return _sw(NfcProtocol.swWrongOffset);
        final end = (offset + NfcProtocol.chunkSize).clamp(0, payload.length);
        final response = _sw(NfcProtocol.swOk, [
          (payload.length >> 8) & 0xFF,
          payload.length & 0xFF,
          ...payload.sublist(offset, end),
        ]);
        if (end == payload.length) onRead?.call();
        return response;

      case NfcProtocol.insPutData:
        if (!acceptWrites) return _sw(NfcProtocol.swNotAccepting);
        final offset = (apdu[2] << 8) | apdu[3];
        final lc = apdu[4];
        if (apdu.length < 5 + lc) return _sw(NfcProtocol.swWrongLength);
        var data = apdu.sublist(5, 5 + lc);

        if (offset == 0) {
          if (data.length < 2) return _sw(NfcProtocol.swWrongLength);
          final total = (data[0] << 8) | data[1];
          if (total == 0 || total > NfcProtocol.maxPayloadBytes) {
            return _sw(NfcProtocol.swWrongLength);
          }
          _incoming = Uint8List(total);
          _incomingTotal = total;
          _incomingLength = 0;
          data = data.sublist(2);
        }

        final buffer = _incoming;
        if (buffer == null || offset != _incomingLength) return _sw(NfcProtocol.swWrongOffset);
        if (_incomingLength + data.length > _incomingTotal) {
          _incoming = null;
          return _sw(NfcProtocol.swWrongLength);
        }
        buffer.setRange(_incomingLength, _incomingLength + data.length, data);
        _incomingLength += data.length;

        if (_incomingLength == _incomingTotal) {
          _incoming = null;
          onWritten?.call(buffer);
        }
        return _sw(NfcProtocol.swOk);

      default:
        return _sw(NfcProtocol.swUnknown);
    }
  }
}

/// A [TagLink] wired straight to an [HceTagEmulator] — the whole tap, in
/// process. Public so other tests (and the emulator-free demo path) can use it.
class EmulatedTagLink implements TagLink {
  EmulatedTagLink(this.tag, {this.alreadySelected = false});

  final HceTagEmulator tag;

  @override
  final bool alreadySelected;

  /// Every command sent, for tests asserting on chunking.
  final List<Uint8List> sent = [];

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    sent.add(apdu);
    return tag.process(apdu);
  }
}
