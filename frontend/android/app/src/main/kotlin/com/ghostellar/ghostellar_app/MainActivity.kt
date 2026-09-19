package com.ghostellar.ghostellar_app

import com.ghostellar.ghostellar_app.nfc.HceService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val nfcHceChannel = "ghostellar/nfc_hce"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nfcHceChannel)
            .setMethodCallHandler { call, result ->
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
    }
}
