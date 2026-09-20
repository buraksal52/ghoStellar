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
                    val payload = call.argument<String>("payload")
                    HceService.currentPayload = payload?.toByteArray(Charsets.UTF_8)
                    result.success(null)
                }
                "stopBroadcast" -> {
                    HceService.currentPayload = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // HostApduService and the Flutter engine share this process, so the
        // read signal is a plain callback — no IPC. The APDU thread is not
        // guaranteed to be the platform thread, so hop before touching the
        // channel.
        val main = Handler(Looper.getMainLooper())
        HceService.onPayloadRead = {
            main.post { channel.invokeMethod("payloadRead", null) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Drop the callback so a dead engine's channel is never invoked, and
        // stop offering a payload nobody on this screen is managing any more.
        HceService.onPayloadRead = null
        HceService.currentPayload = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
