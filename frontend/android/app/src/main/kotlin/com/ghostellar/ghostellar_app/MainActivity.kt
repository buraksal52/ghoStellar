package com.ghostellar.ghostellar_app

import android.os.Handler
import android.os.Looper
import com.ghostellar.ghostellar_app.nfc.HceService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val nfcHceChannel = "ghostellar/nfc_hce"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nfcHceChannel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startBroadcast" -> {
                    // `payload` is raw bytes (or null: nothing to offer yet).
                    HceService.offer = call.argument<ByteArray>("payload")
                    HceService.acceptWrites = call.argument<Boolean>("acceptWrites") ?: false
                    result.success(null)
                }
                "stopBroadcast" -> {
                    HceService.offer = null
                    HceService.acceptWrites = false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // HostApduService and the Flutter engine share this process, so the
        // signals are plain callbacks — no IPC. The APDU thread is not
        // guaranteed to be the platform thread, so hop before touching the
        // channel.
        val main = Handler(Looper.getMainLooper())
        HceService.onRead = {
            main.post { channel.invokeMethod("payloadRead", null) }
        }
        HceService.onWritten = { bytes ->
            main.post { channel.invokeMethod("payloadWritten", bytes) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Drop the callbacks so a dead engine's channel is never invoked, and
        // stop offering / accepting anything nobody on this screen manages.
        HceService.onRead = null
        HceService.onWritten = null
        HceService.offer = null
        HceService.acceptWrites = false
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
