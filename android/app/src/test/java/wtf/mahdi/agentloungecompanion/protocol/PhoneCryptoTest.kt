package wtf.mahdi.agentloungecompanion.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.interfaces.ECPublicKey

/** Same vectors as the Mac tests (`PhoneCryptoVectorTests` in AgentLoungeTests/RemoteTests.swift). */
class PhoneCryptoTest {
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    private fun unhex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun bytes(start: Int, count: Int) = ByteArray(count) { (start + it).toByte() }

    @Test
    fun sessionKeysAndFirstFrame() {
        val (p2m, m2p) = PhoneCrypto.sessionKeys(bytes(1, 32), bytes(0xA0, 16), bytes(0xB0, 16))
        assertEquals("f24bf037517780f16c1d30f84bbe5ac11b92fb2e59ab11280c250b6d8bda477b", hex(p2m))
        assertEquals("e90deab804f097bb67a29ed2df85714de2b8934c4fae3b8ce0120d6c942d1fc6", hex(m2p))
        val frame = FrameSealer(p2m).seal("""{"type":"auth"}""".encodeToByteArray())
        assertEquals("0000000000000000000000004902c8c4c9dcfdab729c425fc02ba115f26e1bf70ff262a1ad9a723374da38", hex(frame))
    }

    @Test
    fun proofPairKeyAndBox() {
        val pub = byteArrayOf(4) + ByteArray(64) { 0x11 }
        assertEquals("3ac454726bb5e2851d2d7ad32bf408a7b19755651b4061e5b64ec3d1d631b658", hex(PhoneCrypto.proof("123456", pub)))

        val macPub = unhex(
            "04550f471003f3df97c3df506ac797f6721fb1a1fb7b8f6f83d224498a65c88e24136093d7012e509a73715cbd0b00a3cc0ff4b5c01b3ffa196ab1fb327036b8e6",
        )
        val phone = PhoneCrypto.privateKey(ByteArray(32) { 3 })
        val key = PhoneCrypto.pairKey(phone, macPub, "123456")
        assertEquals("5e0cd2a8f8228a46c5be79338158d7c5daa5380e1cfa975181ead3f6b725b1ef", hex(key))

        val box = unhex(
            "404142434445464748494a4b2ffbfa749244868b23567508c8eb24d5d5d0aea9b63a8f153266935ee788be16800a20a44db5a75e61fcf876c60877ce1b7afc1501cae5ba9af1f6f27ea1295cfb570920731c2f8315e60b740fcf60e8",
        )
        assertEquals(
            """{"deviceId":"d1","secret":"AQID","server":"Mac","serverId":"s1"}""",
            PhoneCrypto.openBox(box, key).decodeToString(),
        )
    }

    @Test
    fun x963RoundTripAndBothSidesAgree() {
        val phone = PhoneCrypto.newKeyPair()
        val mac = PhoneCrypto.newKeyPair()
        val phonePub = PhoneCrypto.x963(phone.public as ECPublicKey)
        val macPub = PhoneCrypto.x963(mac.public as ECPublicKey)
        assertEquals(65, phonePub.size)
        assertArrayEquals(phonePub, PhoneCrypto.x963(PhoneCrypto.publicKey(phonePub)))
        assertArrayEquals(
            PhoneCrypto.pairKey(phone.private, macPub, "000001"),
            PhoneCrypto.pairKey(mac.private, phonePub, "000001"),
        )
    }

    @Test
    fun openerRefusesReplayAndTampering() {
        val key = PhoneCrypto.randomBytes(32)
        val sealer = FrameSealer(key)
        val opener = FrameOpener(key)
        val first = sealer.seal("a".encodeToByteArray())
        val second = sealer.seal("b".encodeToByteArray())
        assertThrows(CryptoFailure::class.java) { opener.open(second) }
        assertEquals("a", opener.open(first).decodeToString())
        assertThrows(CryptoFailure::class.java) { opener.open(first) }
        val tampered = second.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertThrows(Exception::class.java) { opener.open(tampered) }
        assertEquals("b", opener.open(second).decodeToString())
    }
}
