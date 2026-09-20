package com.ghostellar.ghostellar_app.nfc

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

/**
 * Host Card Emulation service for the "Ready to Receive" NFC handshake.
 *
 * Responds to two APDU commands from [NfcService.startScan]'s reader
 * session:
 *  - SELECT AID (00 A4 04 00 <len> <aid> 00) for our proprietary AID
 *    F047686F53746C — replies with success (90 00) if selected.
 *  - GET DATA (00 CA 00 00 00) — replies with the currently broadcasting
 *    payload as UTF-8 bytes, followed by success (90 00), or a
 *    "no data" status (6A 82) if nothing is being broadcast right now.
 *
 * The payload to broadcast (a payment-request or cheque-handoff URI, see
 * `payment_uri.dart`) is set/cleared from Flutter via the
 * `ghostellar/nfc_hce` MethodChannel (see MainActivity), never hardcoded —
 * this service only ever emits whatever the app is currently offering, for
 * as long as a Receive/Send session is active.
 *
 * After a successful GET DATA it fires [onPayloadRead], which is how the
 * broadcaster learns "the other phone has it" and can move on to the next
 * step of the flow.
 */
class HceService : HostApduService() {

    companion object {
        private const val CLA_INS_P1_P2_LEN = 5
        private val AID = byteArrayOf(0xF0.toByte(), 0x47, 0x68, 0x6F, 0x53, 0x74, 0x6C)
        private const val INS_SELECT = 0xA4.toByte()
        private const val INS_GET_DATA = 0xCA.toByte()
        private val SW_SUCCESS = byteArrayOf(0x90.toByte(), 0x00)
        private val SW_NO_DATA = byteArrayOf(0x6A, 0x82.toByte())
        private val SW_UNKNOWN = byteArrayOf(0x6D, 0x00)

        /** Set by Flutter when a Receive/Send session starts broadcasting; null when idle. */
        @Volatile
        var currentPayload: ByteArray? = null

        /** Set by MainActivity; invoked after a reader successfully received [currentPayload]. */
        @Volatile
        var onPayloadRead: (() -> Unit)? = null
    }

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        if (commandApdu == null || commandApdu.size < CLA_INS_P1_P2_LEN) return SW_UNKNOWN

        return when (commandApdu[1]) {
            INS_SELECT -> {
                val aidLen = commandApdu[4].toInt() and 0xFF
                // A malformed APDU from an arbitrary reader must not crash the service.
                if (commandApdu.size < 5 + aidLen) return SW_UNKNOWN
                val aid = commandApdu.copyOfRange(5, 5 + aidLen)
                if (aid.contentEquals(AID)) SW_SUCCESS else SW_UNKNOWN
            }
            INS_GET_DATA -> {
                val payload = currentPayload
                if (payload == null) {
                    SW_NO_DATA
                } else {
                    onPayloadRead?.invoke()
                    payload + SW_SUCCESS
                }
            }
            else -> SW_UNKNOWN
        }
    }

    override fun onDeactivated(reason: Int) {
        // Session ended (link lost or another AID selected) — nothing to
        // clean up here; the payload lifecycle is owned by Flutter via the
        // start/stopBroadcast channel calls, not by tap duration.
    }
}
