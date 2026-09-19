import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

/// Real NFC handshake between two phones, used only to exchange the
/// receiver's Stellar address (+ an optional session id) before the normal
/// REST + sign + submit pipeline takes over — NFC is never the settlement
/// rail, just the proximity handshake.
///
/// Platform split (deliberate, not a bug): Android can both broadcast (Host
/// Card Emulation, via a native `HostApduService` reached over a platform
/// channel — no Flutter NFC plugin exposes HCE emulate-mode) and read
/// (`nfc_manager`'s ISO-DEP reader mode). iOS's Core NFC framework does not
/// allow third-party apps to emulate a tag for another phone to read, so
/// [isEmulateSupported] is always false there — the UI must fall back to
/// QR/Link on iOS, it should never imply a working "Tap to Send/Receive".
class NfcService {
  static const _hceChannel = MethodChannel('ghostellar/nfc_hce');

  /// Custom, unregistered AID under the proprietary `F0` prefix — fine for
  /// this MVP's own app-to-app handshake, not a payment network AID.
  static const List<int> _aid = [0xF0, 0x47, 0x68, 0x6F, 0x53, 0x74, 0x6C];
  static const int _insGetAddress = 0xCA;

  bool get isEmulateSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> get isReaderSupported async {
    final availability = await NfcManager.instance.checkAvailability();
    return availability == NfcAvailability.enabled;
  }

  /// Android only. Starts broadcasting [stellarAddress] via HCE so another
  /// phone can read it by tapping. No-op (throws) on other platforms.
  Future<void> startReceiveBroadcast(String stellarAddress) async {
    if (!isEmulateSupported) {
      throw UnsupportedError('NFC emulate/broadcast is Android-only.');
    }
    await _hceChannel.invokeMethod('startBroadcast', {
      'aid': _aid,
      'payload': stellarAddress,
    });
  }

  Future<void> stopReceiveBroadcast() async {
    if (!isEmulateSupported) return;
    await _hceChannel.invokeMethod('stopBroadcast');
  }

  /// Starts an NFC reader session and returns the first discovered
  /// broadcaster's Stellar address (Android/HCE peer), or null if the
  /// session was stopped/timed out without a match.
  Future<String?> startSendScan({Duration timeout = const Duration(seconds: 30)}) async {
    final completer = Completer<String?>();

    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      onDiscovered: (tag) async {
        try {
          final isoDep = IsoDepAndroid.from(tag);
          if (isoDep == null) {
            return; // Not an ISO-DEP (HCE) tag — ignore, keep polling.
          }
          final selectApdu = _buildSelectApdu(_aid);
          final selectResp = await isoDep.transceive(selectApdu);
          if (!_isSuccess(selectResp)) return;

          final getApdu = _buildGetDataApdu();
          final resp = await isoDep.transceive(getApdu);
          if (!_isSuccess(resp)) return;

          final address = utf8.decode(resp.sublist(0, resp.length - 2));
          if (!completer.isCompleted) completer.complete(address);
        } catch (_) {
          // Swallow and keep polling — a misread shouldn't kill the session.
        } finally {
          await NfcManager.instance.stopSession();
        }
      },
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        NfcManager.instance.stopSession();
        return null;
      },
    );
  }

  Future<void> cancelSendScan() => NfcManager.instance.stopSession();

  static Uint8List _buildSelectApdu(List<int> aid) {
    return Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, aid.length, ...aid, 0x00]);
  }

  static Uint8List _buildGetDataApdu() {
    return Uint8List.fromList([0x00, _insGetAddress, 0x00, 0x00, 0x00]);
  }

  static bool _isSuccess(Uint8List response) {
    if (response.length < 2) return false;
    return response[response.length - 2] == 0x90 &&
        response[response.length - 1] == 0x00;
  }
}
