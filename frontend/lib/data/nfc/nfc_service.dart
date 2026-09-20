import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

/// Real NFC handshake between two phones. It carries short URIs — a payment
/// request (receiver -> sender) and a cheque handoff (sender -> receiver),
/// both defined in `core/payments/payment_uri.dart` — before or after the
/// normal REST + sign + submit pipeline. NFC is never the settlement rail,
/// just the proximity handshake; this class moves opaque strings and leaves
/// parsing and validation to the caller.
///
/// Platform split (deliberate, not a bug): Android can both broadcast (Host
/// Card Emulation, via a native `HostApduService` reached over a platform
/// channel — no Flutter NFC plugin exposes HCE emulate-mode) and read
/// (`nfc_manager`'s ISO-DEP reader mode). iOS's Core NFC framework does not
/// allow third-party apps to emulate a tag for another phone to read, and
/// reading another phone's HCE needs an ISO 7816 select-identifiers
/// entitlement we don't ship, so both flags are false there — the UI must
/// fall back to QR on iOS, it should never imply a working "Tap to Send".
class NfcService {
  static const _hceChannel = MethodChannel('ghostellar/nfc_hce');

  /// Custom, unregistered AID under the proprietary `F0` prefix — fine for
  /// this MVP's own app-to-app handshake, not a payment network AID.
  static const List<int> _aid = [0xF0, 0x47, 0x68, 0x6F, 0x53, 0x74, 0x6C];
  static const int _insGetData = 0xCA;

  /// A short-APDU response carries at most 256 data bytes; leave headroom
  /// for the 2 status bytes rather than discovering the limit on a device.
  static const int maxPayloadBytes = 240;

  StreamController<void>? _readController;
  Completer<String?>? _activeScan;

  bool get isEmulateSupported => defaultTargetPlatform == TargetPlatform.android;
  bool get isScanSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> get isReaderSupported async {
    return NfcManager.instance.isAvailable();
  }

  /// Fires each time a reader successfully pulled the current broadcast
  /// payload — how the broadcaster learns "the other phone has it". A reader
  /// may retry GET DATA, so consumers must treat repeats as the same event.
  Stream<void> get onPayloadRead {
    var controller = _readController;
    if (controller == null) {
      controller = StreamController<void>.broadcast();
      _readController = controller;
      _hceChannel.setMethodCallHandler((call) async {
        if (call.method == 'payloadRead') controller!.add(null);
      });
    }
    return controller.stream;
  }

  /// Android only. Starts offering [payload] via HCE so another phone can
  /// read it by tapping. Throws on other platforms and for a payload the
  /// APDU response cannot carry.
  Future<void> startBroadcast(String payload) async {
    if (!isEmulateSupported) {
      throw UnsupportedError('NFC emulate/broadcast is Android-only.');
    }
    if (utf8.encode(payload).length > maxPayloadBytes) {
      throw ArgumentError.value(payload.length, 'payload', 'too long for one NFC response');
    }
    await _hceChannel.invokeMethod('startBroadcast', {
      'aid': _aid,
      'payload': payload,
    });
  }

  Future<void> stopBroadcast() async {
    if (!isEmulateSupported) return;
    await _hceChannel.invokeMethod('stopBroadcast');
  }

  /// Starts an NFC reader session and returns the first payload read from a
  /// broadcasting peer, or null if the session was cancelled or timed out
  /// without one. The payload is unvalidated text.
  ///
  /// A misread (not ISO-DEP, wrong AID, garbled bytes) does not end the
  /// session — the peer stays in the field and we keep waiting until the
  /// timeout, so one bad exchange doesn't force the user to restart.
  Future<String?> startScan({Duration timeout = const Duration(seconds: 30)}) async {
    if (!isScanSupported) return null;
    // One reader session at a time: a second caller joins the running one
    // instead of cancelling it (its teardown would stop the new session).
    final running = _activeScan;
    if (running != null) return running.future;

    final completer = Completer<String?>();
    _activeScan = completer;

    try {
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443},
        onDiscovered: (tag) async {
          try {
            final payload = await _read(tag);
            if (payload != null && !completer.isCompleted) completer.complete(payload);
          } catch (_) {
            // Keep polling — a misread shouldn't kill the session.
          }
        },
      );
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      if (identical(_activeScan, completer)) _activeScan = null;
      try {
        await NfcManager.instance.stopSession();
      } catch (_) {
        // Already stopped (e.g. by the OS) — nothing to release.
      }
    }
  }

  /// Ends a running [startScan] promptly; it resolves to null.
  Future<void> cancelScan() async {
    final scan = _activeScan;
    if (scan != null && !scan.isCompleted) scan.complete(null);
  }

  Future<String?> _read(NfcTag tag) async {
    final isoDep = IsoDepAndroid.from(tag);
    if (isoDep == null) return null; // Not an ISO-DEP (HCE) tag.

    final selectResp = await isoDep.transceive(_buildSelectApdu(_aid));
    if (!_isSuccess(selectResp)) return null;

    final resp = await isoDep.transceive(_buildGetDataApdu());
    if (!_isSuccess(resp)) return null;

    return utf8.decode(resp.sublist(0, resp.length - 2));
  }

  static Uint8List _buildSelectApdu(List<int> aid) {
    return Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, aid.length, ...aid, 0x00]);
  }

  static Uint8List _buildGetDataApdu() {
    return Uint8List.fromList([0x00, _insGetData, 0x00, 0x00, 0x00]);
  }

  static bool _isSuccess(Uint8List response) {
    if (response.length < 2) return false;
    return response[response.length - 2] == 0x90 &&
        response[response.length - 1] == 0x00;
  }
}
