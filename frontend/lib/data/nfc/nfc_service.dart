import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import 'nfc_frame.dart';

/// Which side of the tap a device plays.
enum NfcRole {
  /// Present a payload as a tag (Android Host Card Emulation) and accept
  /// writes. Continuous until [NfcService.stop].
  tag,

  /// Read the other phone's tag, and write ours. One shot: ends after the
  /// first successful exchange or the timeout. The only role an iPhone has.
  reader,

  /// Android only: alternate short reader windows with tag windows, so it
  /// works against another Android (either may be the reader) *and* an
  /// iPhone (which can only read). Continuous until [NfcService.stop].
  auto,
}

/// Real NFC handshake between two phones. It carries short URIs — a payment
/// request and a cheque handoff, both defined in
/// `core/payments/payment_uri.dart` — and moves them in **both directions in
/// one tap** (see [NfcProtocol]). NFC is never the settlement rail, just the
/// proximity handshake; this class moves opaque strings and leaves parsing
/// and validation to the caller.
///
/// Platform split (deliberate, not a bug): Android can both present (Host
/// Card Emulation, via a native `HostApduService` reached over a platform
/// channel — no Flutter NFC plugin exposes HCE emulate-mode) and read
/// (`nfc_manager`'s ISO-DEP reader mode). iOS's Core NFC does not let a
/// third-party app emulate a tag, so an iPhone is reader-only. That makes
/// iPhone↔Android work in both directions, and **iPhone↔iPhone impossible
/// over NFC** — the UI falls back to QR there. (Apple's HCE API exists only
/// in the EU/Japan behind an Apple-approved entitlement.)
class NfcService {
  NfcService({
    ReaderTransport? reader,
    TagTransport? tag,
    TargetPlatform? platform,
    this.readerWindow = const Duration(milliseconds: 1500),
    this.tagWindow = const Duration(milliseconds: 1500),
    this.readerTimeout = const Duration(seconds: 30),
  })  : _reader = reader ?? NfcManagerReaderTransport(),
        _tag = tag,
        _platform = platform ?? defaultTargetPlatform;

  final ReaderTransport _reader;
  TagTransport? _tag;
  final TargetPlatform _platform;

  /// [NfcRole.auto]: how long each reader window and each tag (listen)
  /// window lasts.
  final Duration readerWindow;
  final Duration tagWindow;

  /// [NfcRole.reader]: give up after this long with no exchange.
  final Duration readerTimeout;

  final _peer = StreamController<String>.broadcast();
  final _delivered = StreamController<void>.broadcast();
  StreamSubscription<void>? _readSub;
  StreamSubscription<Uint8List>? _writtenSub;

  NfcRole? _role;
  String? _offer;
  int _epoch = 0;
  Completer<void>? _window;
  String? _lastPeer;
  String? _lastDeliveredOffer;

  bool get canBeTag => _platform == TargetPlatform.android;
  bool get canRead => _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  /// Whether this phone can take part in NFC at all.
  bool get isAvailable => canBeTag || canRead;

  /// The role this device plays when it is the one *showing* a request.
  NfcRole get receiverRole => canBeTag ? NfcRole.tag : NfcRole.reader;

  /// The role this device plays when it is the one *paying*.
  NfcRole get senderRole => canBeTag ? NfcRole.auto : NfcRole.reader;

  /// Whether the OS hardware is on (a device with NFC can still have it off).
  Future<bool> get isHardwareEnabled => NfcManager.instance.isAvailable();

  /// A payload the other phone handed us — read from its tag, or written to
  /// ours. Unvalidated text. A payload identical to the previous one is not
  /// re-emitted, so a phone resting on ours doesn't fire it every window.
  Stream<String> get onPeerPayload => _peer.stream;

  /// The other phone now has our offer: it read the whole tag payload, or we
  /// wrote it to them in full. May repeat for a new offer, never for the same.
  Stream<void> get onDelivered => _delivered.stream;

  /// Starts (or restarts) a session. [offer] is what we present/write, or
  /// null when we have nothing to give yet (a sender waiting for a request).
  Future<void> start({required NfcRole role, String? offer}) async {
    await stop();
    if (!isAvailable) throw UnsupportedError('NFC is not available on this platform.');
    if (role == NfcRole.tag && !canBeTag) {
      throw UnsupportedError('This device cannot present as an NFC tag.');
    }
    if (role == NfcRole.reader && !canRead) {
      throw UnsupportedError('This device cannot read NFC tags.');
    }
    if (offer != null && utf8.encode(offer).length > NfcProtocol.maxPayloadBytes) {
      throw ArgumentError.value(offer.length, 'offer', 'too long for NFC');
    }

    final epoch = ++_epoch;
    _offer = offer;
    _lastPeer = null;
    _lastDeliveredOffer = null;
    // A device that cannot be a tag has only one way to take part.
    _role = role == NfcRole.auto && !canBeTag ? NfcRole.reader : role;

    if (_role == NfcRole.tag || _role == NfcRole.auto) await _present();
    if (_role == NfcRole.reader) {
      unawaited(_runReader(epoch, continuous: false));
    } else if (_role == NfcRole.auto) {
      unawaited(_runReader(epoch, continuous: true));
    }
  }

  /// Changes what we present/write on the running session (e.g. the request
  /// gives way to the cheque handoff once the cheque is locked).
  Future<void> setOffer(String? offer) async {
    if (offer != null && utf8.encode(offer).length > NfcProtocol.maxPayloadBytes) {
      throw ArgumentError.value(offer.length, 'offer', 'too long for NFC');
    }
    _offer = offer;
    _lastDeliveredOffer = null;
    if (_role == NfcRole.tag || _role == NfcRole.auto) await _present();
  }

  /// Ends the session: stops presenting, closes any reader window.
  Future<void> stop() async {
    _epoch++;
    final window = _window;
    if (window != null && !window.isCompleted) window.complete();
    if (_role != null) {
      _role = null;
      try {
        await _reader.stop();
      } catch (_) {
        // Not running.
      }
      try {
        await _tag?.stop();
      } catch (_) {
        // Not presenting.
      }
    }
  }

  // ---- internals ---------------------------------------------------------

  Future<void> _present() async {
    final tag = _tag ??= HceChannelTagTransport();
    _readSub ??= tag.onRead.listen((_) => _emitDelivered(_offer));
    _writtenSub ??= tag.onWritten.listen(_onWritten);
    await tag.present(
      offer: _offer == null ? null : Uint8List.fromList(utf8.encode(_offer!)),
      acceptWrites: true,
    );
  }

  void _onWritten(Uint8List bytes) => _emitPeer(bytes);

  void _emitPeer(Uint8List bytes) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return; // Not text we produced.
    }
    if (text == _lastPeer) return;
    _lastPeer = text;
    _peer.add(text);
  }

  void _emitDelivered(String? offer) {
    if (offer == null) return; // Nothing was on offer; a read means nothing.
    if (offer == _lastDeliveredOffer) return;
    _lastDeliveredOffer = offer;
    _delivered.add(null);
  }

  Future<void> _runReader(int epoch, {required bool continuous}) async {
    while (epoch == _epoch) {
      final exchanged = await _readerWindow(epoch, continuous ? readerWindow : readerTimeout);
      if (epoch != _epoch) return;
      if (!continuous) return; // one shot: done either way.
      // The listen window: our tag answers a reader (an iPhone, or an
      // Android currently in its own reader window).
      await Future<void>.delayed(exchanged ? tagWindow * 2 : tagWindow);
    }
  }

  /// One reader session. Returns whether a ghoStellar tag was exchanged with.
  Future<bool> _readerWindow(int epoch, Duration timeout) async {
    final window = Completer<void>();
    _window = window;
    var exchanged = false;

    try {
      await _reader.start(
        alertMessage: 'Hold your iPhone near the other phone',
        onEnded: () {
          if (!window.isCompleted) window.complete();
        },
        onLink: (link) async {
          if (epoch != _epoch || exchanged) return;
          final offer = _offer;
          final ExchangeResult? result;
          try {
            result = await readerExchange(
              link,
              offer: offer == null ? null : Uint8List.fromList(utf8.encode(offer)),
            );
          } catch (_) {
            return; // Tag lost mid-tap — keep the window open for another go.
          }
          if (result == null || result.isEmpty) return; // Not ours / nothing to gain.
          exchanged = true;
          final peer = result.peerPayload;
          if (peer != null) _emitPeer(peer);
          if (result.delivered) _emitDelivered(offer);
          if (!window.isCompleted) window.complete();
        },
      );
      await window.future.timeout(timeout, onTimeout: () {});
    } catch (_) {
      // The session couldn't start (NFC off, another session running).
    } finally {
      if (identical(_window, window)) _window = null;
      try {
        await _reader.stop(alertMessage: exchanged ? 'Done' : null);
      } catch (_) {
        // Already ended by the OS.
      }
    }
    return exchanged;
  }
}

// ---- platform seams --------------------------------------------------------

/// Reader mode on the device: Android `IsoDep`, iOS `NFCTagReaderSession`.
abstract interface class ReaderTransport {
  /// Starts a session; [onLink] runs for each discovered tag. [onEnded] fires
  /// if the OS ends the session on its own (iOS: cancel button, 60 s limit).
  Future<void> start({
    required Future<void> Function(TagLink link) onLink,
    void Function()? onEnded,
    String? alertMessage,
  });

  Future<void> stop({String? alertMessage});
}

/// Presenting a tag: Android Host Card Emulation over a platform channel.
abstract interface class TagTransport {
  /// Presents [offer] (null = nothing) and accepts writes when [acceptWrites].
  Future<void> present({required Uint8List? offer, required bool acceptWrites});

  Future<void> stop();

  /// A reader received the whole of our offer.
  Stream<void> get onRead;

  /// A reader wrote a complete payload to us.
  Stream<Uint8List> get onWritten;
}

class NfcManagerReaderTransport implements ReaderTransport {
  @override
  Future<void> start({
    required Future<void> Function(TagLink link) onLink,
    void Function()? onEnded,
    String? alertMessage,
  }) {
    return NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      alertMessageIos: alertMessage,
      onSessionErrorIos: (_) => onEnded?.call(),
      onDiscovered: (tag) async {
        final link = _linkFor(tag);
        if (link != null) await onLink(link);
      },
    );
  }

  @override
  Future<void> stop({String? alertMessage}) =>
      NfcManager.instance.stopSession(alertMessageIos: alertMessage);

  static TagLink? _linkFor(NfcTag tag) {
    final android = IsoDepAndroid.from(tag);
    if (android != null) return _AndroidLink(android);
    final ios = Iso7816Ios.from(tag);
    if (ios != null) return _IosLink(ios);
    return null; // Not an ISO-DEP tag.
  }
}

class _AndroidLink implements TagLink {
  _AndroidLink(this._isoDep);
  final IsoDepAndroid _isoDep;

  @override
  bool get alreadySelected => false;

  @override
  Future<Uint8List> transceive(Uint8List apdu) => _isoDep.transceive(apdu);
}

class _IosLink implements TagLink {
  _IosLink(this._tag);
  final Iso7816Ios _tag;

  /// iOS selects the AIDs declared in Info.plist itself when it discovers the
  /// tag, and reports which one it selected.
  @override
  bool get alreadySelected => _tag.initialSelectedAID.toUpperCase() == NfcProtocol.aidHex;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final r = await _tag.sendCommandRaw(data: apdu);
    return Uint8List.fromList([...r.payload, r.statusWord1, r.statusWord2]);
  }
}

class HceChannelTagTransport implements TagTransport {
  HceChannelTagTransport() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'payloadRead':
          _read.add(null);
        case 'payloadWritten':
          final bytes = call.arguments;
          if (bytes is Uint8List) _written.add(bytes);
      }
    });
  }

  static const _channel = MethodChannel('ghostellar/nfc_hce');

  final _read = StreamController<void>.broadcast();
  final _written = StreamController<Uint8List>.broadcast();

  @override
  Stream<void> get onRead => _read.stream;

  @override
  Stream<Uint8List> get onWritten => _written.stream;

  @override
  Future<void> present({required Uint8List? offer, required bool acceptWrites}) {
    return _channel.invokeMethod('startBroadcast', {
      'aid': NfcProtocol.aid,
      'payload': offer,
      'acceptWrites': acceptWrites,
    });
  }

  @override
  Future<void> stop() => _channel.invokeMethod('stopBroadcast');
}
