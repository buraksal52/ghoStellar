package com.ghostellar.ghostellar_app.nfc

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

/**
 * Host Card Emulation service: the tag side of the ghoStellar NFC exchange.
 *
 * This is a line-for-line mirror of `HceTagEmulator` in
 * `lib/data/nfc/nfc_frame.dart` — that Dart class is the reference behaviour
 * and is what the protocol tests run against. Change one, change the other.
 *
 * One tap is symmetric: the reader phone GETs our payload and PUTs its own.
 * Payloads outrun a single short APDU, so both are chunked by byte offset:
 *
 *  - SELECT AID `F047686F53746C` — replies 90 00; also starts a fresh write.
 *  - GET DATA `00 CA P1 P2 00`, P1P2 = offset → `[total(2)] ‖ chunk(≤200)` 90 00,
 *    or 6A 82 when we offer nothing. Fires [onRead] once the last chunk is out.
 *  - PUT DATA `00 DA P1 P2 Lc data`, P1P2 = payload bytes already sent; the
 *    first chunk (offset 0) is prefixed with `[total(2)]`. Each accepted chunk
 *    answers 90 00; [onWritten] fires when the last lands. 69 85 while we are
 *    not accepting writes.
 *
 * What we offer, and whether we take writes, is set from Flutter over the
 * `ghostellar/nfc_hce` MethodChannel (see MainActivity) — never hardcoded.
 */
class HceService : HostApduService() {

    companion object {
        private const val CLA_INS_P1_P2_LEN = 5
        private val AID = byteArrayOf(0xF0.toByte(), 0x47, 0x68, 0x6F, 0x53, 0x74, 0x6C)
        private const val INS_SELECT = 0xA4.toByte()
        private const val INS_GET_DATA = 0xCA.toByte()
        private const val INS_PUT_DATA = 0xDA.toByte()

        /** Payload bytes per APDU; 200 + 2 length + 2 status stays inside a short APDU. */
        private const val CHUNK = 200

        /** Refuse anything bigger — the length comes from the other phone. */
        private const val MAX_PAYLOAD = 4096

        private val SW_OK = byteArrayOf(0x90.toByte(), 0x00)
        private val SW_NO_DATA = byteArrayOf(0x6A, 0x82.toByte())
        private val SW_WRONG_OFFSET = byteArrayOf(0x6A, 0x86.toByte())
        private val SW_WRONG_LENGTH = byteArrayOf(0x67, 0x00)
        private val SW_NOT_ACCEPTING = byteArrayOf(0x69, 0x85.toByte())
        private val SW_UNKNOWN = byteArrayOf(0x6D, 0x00)

        /** What we present to a reader (null = nothing). Set by Flutter. */
        @Volatile
        var offer: ByteArray? = null

        /** Whether a reader may write to us right now. Set by Flutter. */
        @Volatile
        var acceptWrites: Boolean = false

        /** Set by MainActivity; a reader was served the last chunk of [offer]. */
        @Volatile
        var onRead: (() -> Unit)? = null

        /** Set by MainActivity; a reader wrote a complete payload to us. */
        @Volatile
        var onWritten: ((ByteArray) -> Unit)? = null
    }

    private var incoming: ByteArray? = null
    private var incomingTotal = 0
    private var incomingLength = 0

    private fun sw(status: ByteArray, data: ByteArray = ByteArray(0)): ByteArray = data + status

    private fun u16(hi: Byte, lo: Byte): Int = ((hi.toInt() and 0xFF) shl 8) or (lo.toInt() and 0xFF)

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        if (commandApdu == null || commandApdu.size < CLA_INS_P1_P2_LEN) return SW_UNKNOWN

        return when (commandApdu[1]) {
            INS_SELECT -> {
                val aidLen = commandApdu[4].toInt() and 0xFF
                // A malformed APDU from an arbitrary reader must not crash the service.
                if (commandApdu.size < 5 + aidLen) return SW_UNKNOWN
                val aid = commandApdu.copyOfRange(5, 5 + aidLen)
                if (!aid.contentEquals(AID)) return SW_UNKNOWN
                incoming = null // a fresh tap starts a fresh write
                SW_OK
            }

            INS_GET_DATA -> {
                val payload = offer ?: return SW_NO_DATA
                val offset = u16(commandApdu[2], commandApdu[3])
                if (offset > payload.size) return SW_WRONG_OFFSET
                val end = minOf(offset + CHUNK, payload.size)
                val header = byteArrayOf(
                    ((payload.size shr 8) and 0xFF).toByte(),
                    (payload.size and 0xFF).toByte(),
                )
                val response = sw(SW_OK, header + payload.copyOfRange(offset, end))
                if (end == payload.size) onRead?.invoke()
                response
            }

            INS_PUT_DATA -> {
                if (!acceptWrites) return SW_NOT_ACCEPTING
                val offset = u16(commandApdu[2], commandApdu[3])
                val lc = commandApdu[4].toInt() and 0xFF
                if (commandApdu.size < 5 + lc) return SW_WRONG_LENGTH
                var data = commandApdu.copyOfRange(5, 5 + lc)

                if (offset == 0) {
                    if (data.size < 2) return SW_WRONG_LENGTH
                    val total = u16(data[0], data[1])
                    if (total == 0 || total > MAX_PAYLOAD) return SW_WRONG_LENGTH
                    incoming = ByteArray(total)
                    incomingTotal = total
                    incomingLength = 0
                    data = data.copyOfRange(2, data.size)
                }

                val buffer = incoming
                if (buffer == null || offset != incomingLength) return SW_WRONG_OFFSET
                if (incomingLength + data.size > incomingTotal) {
                    incoming = null
                    return SW_WRONG_LENGTH
                }
                data.copyInto(buffer, incomingLength)
                incomingLength += data.size

                if (incomingLength == incomingTotal) {
                    incoming = null
                    onWritten?.invoke(buffer)
                }
                SW_OK
            }

            else -> SW_UNKNOWN
        }
    }

    override fun onDeactivated(reason: Int) {
        // Link lost or another AID selected: drop any half-written payload so
        // a later tap can't continue it. The offer's lifecycle is owned by
        // Flutter via the start/stopBroadcast channel calls, not by the tap.
        incoming = null
    }
}
