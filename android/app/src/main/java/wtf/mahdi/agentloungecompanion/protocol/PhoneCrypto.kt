package wtf.mahdi.agentloungecompanion.protocol

import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Protocol v2 crypto, same algorithms as the Mac (`AgentLounge/Remote/PhoneCrypto.swift`, PLAN §10):
 * P-256 ECDH + HKDF-SHA256 at pairing, a 32-byte device secret, per-connection keys from
 * HKDF(secret, phoneNonce + macNonce), and AES-256-GCM frames with counter nonces.
 */
object PhoneCrypto {
    const val NONCE_LENGTH = 16
    private val PAIR_INFO = "agentlounge v2 pair".encodeToByteArray()
    private val SESSION_INFO = "agentlounge v2 session".encodeToByteArray()
    internal val FRAME_AAD = "agentlounge v2".encodeToByteArray()
    private const val TAG_BITS = 128
    private val random = SecureRandom()

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)

    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"), random)
    }.generateKeyPair()

    /** Uncompressed point: 0x04 + X (32) + Y (32), like CryptoKit `x963Representation`. */
    fun x963(publicKey: ECPublicKey): ByteArray {
        fun fixed(value: BigInteger): ByteArray {
            val raw = value.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else it }
            return ByteArray(32 - raw.size) + raw
        }
        return byteArrayOf(4) + fixed(publicKey.w.affineX) + fixed(publicKey.w.affineY)
    }

    fun publicKey(x963: ByteArray): ECPublicKey {
        require(x963.size == 65 && x963[0] == 4.toByte()) { "Bad public key" }
        val point = ECPoint(BigInteger(1, x963.copyOfRange(1, 33)), BigInteger(1, x963.copyOfRange(33, 65)))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, p256)) as ECPublicKey
    }

    /** For tests: a private key from its 32-byte scalar. */
    fun privateKey(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), p256))

    fun proof(code: String, publicKey: ByteArray): ByteArray = hmac(code.encodeToByteArray(), publicKey)

    fun pairKey(privateKey: PrivateKey, peerPublicKey: ByteArray, code: String): ByteArray {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(privateKey)
        agreement.doPhase(publicKey(peerPublicKey), true)
        return hkdf(agreement.generateSecret(), code.encodeToByteArray(), PAIR_INFO, 32)
    }

    /** Box = nonce (12) + ciphertext + tag, no AAD (the Mac uses CryptoKit `AES.GCM.seal`). */
    fun openBox(box: ByteArray, key: ByteArray): ByteArray = gcm(Cipher.DECRYPT_MODE, key, box.copyOfRange(0, 12), null)
        .doFinal(box, 12, box.size - 12)

    fun sealBox(plaintext: ByteArray, key: ByteArray): ByteArray {
        val nonce = randomBytes(12)
        return nonce + gcm(Cipher.ENCRYPT_MODE, key, nonce, null).doFinal(plaintext)
    }

    /** First: phone → Mac key. Second: Mac → phone key. */
    fun sessionKeys(secret: ByteArray, phoneNonce: ByteArray, macNonce: ByteArray): Pair<ByteArray, ByteArray> {
        val material = hkdf(secret, phoneNonce + macNonce, SESSION_INFO, 64)
        return material.copyOfRange(0, 32) to material.copyOfRange(32, 64)
    }

    fun frameNonce(counter: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(counter).array()

    internal fun gcm(mode: Int, key: ByteArray, nonce: ByteArray, aad: ByteArray?): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            if (aad != null) updateAAD(aad)
        }

    /** RFC 5869 with HMAC-SHA256. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt, ikm)
        val output = ArrayList<Byte>(length)
        var block = ByteArray(0)
        var counter = 1
        while (output.size < length) {
            block = hmac(prk, block + info + byteArrayOf(counter.toByte()))
            output.addAll(block.toList())
            counter++
        }
        return output.take(length).toByteArray()
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)

    private val p256: ECParameterSpec by lazy { (newKeyPair().public as ECPublicKey).params }
}

class CryptoFailure(message: String) : Exception(message)

/** Encrypts frames of one direction. */
class FrameSealer(private val key: ByteArray) {
    private var counter = 0L

    @Synchronized
    fun seal(plaintext: ByteArray): ByteArray {
        val nonce = PhoneCrypto.frameNonce(counter++)
        return nonce + PhoneCrypto.gcm(Cipher.ENCRYPT_MODE, key, nonce, PhoneCrypto.FRAME_AAD).doFinal(plaintext)
    }
}

/** Decrypts frames of one direction; refuses replayed or reordered frames. */
class FrameOpener(private val key: ByteArray) {
    private var counter = 0L

    @Synchronized
    fun open(frame: ByteArray): ByteArray {
        if (frame.size < 12 + 16) throw CryptoFailure("Short frame")
        val nonce = frame.copyOfRange(0, 12)
        if (!nonce.contentEquals(PhoneCrypto.frameNonce(counter))) throw CryptoFailure("Unexpected frame counter")
        val plain = PhoneCrypto.gcm(Cipher.DECRYPT_MODE, key, nonce, PhoneCrypto.FRAME_AAD).doFinal(frame, 12, frame.size - 12)
        counter++
        return plain
    }
}
