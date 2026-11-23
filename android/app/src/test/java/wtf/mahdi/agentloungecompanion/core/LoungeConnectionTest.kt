package wtf.mahdi.agentloungecompanion.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import wtf.mahdi.agentloungecompanion.data.PairedMac
import wtf.mahdi.agentloungecompanion.net.LoungeSockets
import wtf.mahdi.agentloungecompanion.protocol.AlertKind
import wtf.mahdi.agentloungecompanion.protocol.ErrorCode
import wtf.mahdi.agentloungecompanion.protocol.FrameOpener
import wtf.mahdi.agentloungecompanion.protocol.FrameSealer
import wtf.mahdi.agentloungecompanion.protocol.PhoneCrypto
import wtf.mahdi.agentloungecompanion.protocol.base64
import wtf.mahdi.agentloungecompanion.protocol.unbase64
import java.security.interfaces.ECPublicKey
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Mac side of protocol v2 for tests, built on the same [PhoneCrypto] (checked against CryptoKit vectors). */
private class FakeMac(
    private val secret: ByteArray,
    private val deviceId: String = "dev",
    /** Sent (encrypted) right after a valid auth frame. */
    private val afterAuth: List<String> = emptyList(),
    private val closeAfterAuth: Boolean = false,
) : WebSocketListener() {
    /** Clear text and decrypted messages from the phone. */
    val received = LinkedBlockingQueue<String>()
    @Volatile var socket: WebSocket? = null
    private var sealer: FrameSealer? = null
    private var opener: FrameOpener? = null
    private var authed = false

    fun send(json: String) {
        socket!!.send(sealer!!.seal(json.encodeToByteArray()).toByteString())
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        received.add(text)
        val message = Json.parseToJsonElement(text).jsonObject
        if (message.string("type") != "hello") return
        if (message.string("deviceId") != deviceId) {
            webSocket.send("""{"type":"error","error":"badToken","v":2}""")
            webSocket.close(1000, null)
            return
        }
        val macNonce = PhoneCrypto.randomBytes(16)
        val (p2m, m2p) = PhoneCrypto.sessionKeys(secret, message.string("nonce")!!.unbase64()!!, macNonce)
        opener = FrameOpener(p2m)
        sealer = FrameSealer(m2p)
        socket = webSocket
        webSocket.send("""{"type":"challenge","nonce":"${macNonce.base64()}","v":2}""")
    }

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
        val plain = opener!!.open(bytes.toByteArray()).decodeToString()
        received.add(plain)
        if (!authed && plain.contains("\"auth\"")) {
            authed = true
            afterAuth.forEach(::send)
            if (closeAfterAuth) webSocket.close(1000, null)
        }
    }

    private fun JsonObject.string(key: String) = get(key)?.jsonPrimitive?.content
}

class LoungeConnectionTest {
    private lateinit var server: MockWebServer
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val store = FakeStore()
    private val secret = PhoneCrypto.randomBytes(32)
    private val welcome = """{"type":"welcome","server":"Studio","serverId":"srv","deviceId":"dev","v":2}"""

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        scope.cancel()
        server.close()
    }

    private fun serve(mac: WebSocketListener) {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(mac).build())
    }

    private fun connection() = LoungeConnection(store = store, finder = { _, _ -> null }, sockets = LoungeSockets(), scope = scope)

    private fun paired() = PairedMac("srv", "Mac", server.hostName, server.port, secret.base64(), "dev")

    @Test
    fun handshakeThenSnapshotAndAlert() = runBlocking<Unit> {
        val mac = FakeMac(
            secret,
            afterAuth = listOf(
                welcome,
                """{"type":"snapshot","sessions":[{"id":"claude:a","state":"needsInput","title":"app"}],"v":2}""",
                """{"type":"alert","alert":{"kind":"needsInput","cardId":"claude:a","title":"app","message":"Allow?"},"v":2}""",
            ),
        )
        serve(mac)
        store.mac.value = paired()
        val connection = connection()
        val alert = scope.async { connection.alerts.first() }
        connection.start()
        connection.hold("test")

        withTimeout(5_000) { connection.state.first { it is ConnectionState.Connected } }
        val hello = mac.received.poll(1, TimeUnit.SECONDS)!!
        assertTrue(hello, hello.contains("\"type\":\"hello\"") && hello.contains("\"deviceId\":\"dev\"") && hello.contains("\"v\":2"))
        assertEquals("""{"type":"auth"}""", mac.received.poll(1, TimeUnit.SECONDS))
        withTimeout(5_000) { connection.cards.first { it.isNotEmpty() } }
        assertEquals("claude:a", connection.cards.value.single().id)
        assertEquals(AlertKind.NEEDS_INPUT, withTimeout(5_000) { alert.await() }.kind)
        withTimeout(5_000) { store.mac.first { it?.name == "Studio" } }
    }

    @Test
    fun wrongSecretNeverConnects() = runBlocking<Unit> {
        // The Mac knows another secret: the phone's auth frame cannot be opened.
        val mac = object : WebSocketListener() {
            val inner = FakeMac(PhoneCrypto.randomBytes(32), afterAuth = listOf(welcome))
            val failed = LinkedBlockingQueue<Boolean>()
            override fun onMessage(webSocket: WebSocket, text: String) = inner.onMessage(webSocket, text)
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val ok = runCatching { inner.onMessage(webSocket, bytes) }.isSuccess
                failed.add(!ok)
                if (!ok) webSocket.close(1000, null)
            }
        }
        serve(mac)
        store.mac.value = paired()
        val connection = connection()
        connection.start()
        connection.hold("test")
        assertEquals(true, mac.failed.poll(5, TimeUnit.SECONDS))
        withTimeout(5_000) { connection.state.first { it is ConnectionState.Waiting } }
    }

    @Test
    fun unknownDeviceForgetsTheMac() = runBlocking<Unit> {
        serve(FakeMac(secret, deviceId = "other"))
        store.mac.value = paired()
        val connection = connection()
        connection.start()
        connection.hold("test")

        // NotPaired is also the first state: wait for the store change first.
        withTimeout(5_000) { store.mac.first { it == null } }
        withTimeout(5_000) { connection.state.first { it == ConnectionState.NotPaired } }
        assertEquals(ErrorCode.BAD_TOKEN, connection.pairingLost.value)
    }

    @Test
    fun revokedInsideTheSessionForgetsTheMac() = runBlocking<Unit> {
        serve(FakeMac(secret, afterAuth = listOf(welcome, """{"type":"error","error":"revoked","v":2}"""), closeAfterAuth = true))
        store.mac.value = paired()
        val connection = connection()
        connection.start()
        connection.hold("test")
        withTimeout(5_000) { store.mac.first { it == null } }
        assertEquals(ErrorCode.REVOKED, connection.pairingLost.value)
    }

    @Test
    fun noHolderMeansPaused() = runBlocking<Unit> {
        store.mac.value = paired()
        val connection = connection()
        connection.start()
        withTimeout(5_000) { connection.state.first { it == ConnectionState.Paused } }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun lostConnectionWaitsThenRetries() = runBlocking<Unit> {
        serve(FakeMac(secret, afterAuth = listOf(welcome), closeAfterAuth = true))
        serve(FakeMac(secret, afterAuth = listOf(welcome)))
        store.mac.value = paired()
        val connection = connection()
        connection.start()
        connection.hold("test")

        withTimeout(5_000) { connection.state.first { it is ConnectionState.Waiting } }
        connection.retry()
        withTimeout(5_000) { connection.state.first { it is ConnectionState.Connected } }
        assertTrue(server.requestCount >= 2)
    }

    @Test
    fun decideAndPromptAreEncryptedAndClearedBySnapshot() = runBlocking<Unit> {
        val mac = FakeMac(
            secret,
            afterAuth = listOf(
                welcome,
                """{"type":"snapshot","sessions":[{"id":"claude:a","state":"needsInput",""" +
                    """"approval":{"id":"r1","tool":"Bash","title":"Run rm","detail":"rm x"}}]}""",
            ),
        )
        serve(mac)
        store.mac.value = paired()
        val connection = connection()
        assertTrue("not connected yet", !connection.decide("r1", true))
        connection.start()
        connection.hold("test")
        withTimeout(5_000) { connection.cards.first { it.firstOrNull()?.approval != null } }

        assertTrue(connection.decide("r1", true))
        assertEquals(setOf("r1"), connection.sentDecisions.value)
        mac.received.poll(1, TimeUnit.SECONDS) // hello
        mac.received.poll(1, TimeUnit.SECONDS) // auth
        assertEquals("""{"type":"decide","requestId":"r1","allow":true}""", mac.received.poll(2, TimeUnit.SECONDS))
        assertTrue(connection.prompt("claude:a", "run the tests"))
        assertEquals("""{"type":"prompt","cardId":"claude:a","text":"run the tests"}""", mac.received.poll(2, TimeUnit.SECONDS))

        val result = scope.async { connection.promptResults.first() }
        mac.send("""{"type":"result","cardId":"claude:a","ok":false,"reason":"Not a Ghostty session"}""")
        assertEquals("Not a Ghostty session", withTimeout(5_000) { result.await() }.reason)

        mac.send("""{"type":"snapshot","sessions":[{"id":"claude:a","state":"running"}]}""")
        withTimeout(5_000) { connection.sentDecisions.first { it.isEmpty() } }
    }

    @Test
    fun pairSavesTheMac() = runBlocking<Unit> {
        val macSecret = PhoneCrypto.randomBytes(32)
        serve(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = Json.parseToJsonElement(text).jsonObject
                val pub = message["pub"]!!.jsonPrimitive.content.unbase64()!!
                val proof = message["proof"]!!.jsonPrimitive.content.unbase64()!!
                if (!proof.contentEquals(PhoneCrypto.proof("123456", pub))) {
                    webSocket.send("""{"type":"error","error":"badCode","v":2}""")
                    return
                }
                val keys = PhoneCrypto.newKeyPair()
                val key = PhoneCrypto.pairKey(keys.private, pub, "123456")
                val box = PhoneCrypto.sealBox(
                    """{"secret":"${macSecret.base64()}","deviceId":"d1","server":"Mac","serverId":"srv"}""".encodeToByteArray(),
                    key,
                )
                val macPub = PhoneCrypto.x963(keys.public as ECPublicKey)
                webSocket.send("""{"type":"paired","pub":"${macPub.base64()}","box":"${box.base64()}","v":2}""")
            }
        })
        val outcome = connection().pair(server.hostName, server.port, "123456", "Pixel")
        assertEquals(PairOutcome.Success, outcome)
        assertEquals(PairedMac("srv", "Mac", server.hostName, server.port, macSecret.base64(), "d1"), store.mac.value)
    }

    @Test
    fun pairWithWrongCode() = runBlocking<Unit> {
        serve(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                assertTrue("code must not be sent", !text.contains("000000"))
                webSocket.send("""{"type":"error","error":"badCode","v":2}""")
                webSocket.close(1000, null)
            }
        })
        val outcome = connection().pair(server.hostName, server.port, "000000", "Pixel")
        assertEquals(PairOutcome.Refused(ErrorCode.BAD_CODE), outcome)
        assertEquals(null, store.mac.value)
    }

    @Test
    fun welcomeAddressesAreStoredWithoutReconnect() = runBlocking<Unit> {
        val mac = FakeMac(
            secret,
            afterAuth = listOf("""{"type":"welcome","server":"Mac","serverId":"srv","deviceId":"dev","addresses":["192.168.1.5","100.69.105.56"],"v":2}"""),
        )
        serve(mac)
        store.mac.value = paired()
        val connection = connection()
        connection.start()
        connection.hold("test")
        withTimeout(5_000) { store.mac.first { it?.otherHosts?.isNotEmpty() == true } }
        assertEquals(listOf("192.168.1.5", "100.69.105.56"), store.mac.value!!.otherHosts)
        // The host list change must not restart the connection.
        Thread.sleep(300)
        assertEquals(1, server.requestCount)
        assertTrue(connection.state.value is ConnectionState.Connected)
    }

    @Test
    fun deadHostFallsBackToOtherHostAtOnce() = runBlocking<Unit> {
        // First host: a plain 404 (no WebSocket) fails at once. Second host: same server by its IP literal.
        server.enqueue(MockResponse.Builder().code(404).build())
        serve(FakeMac(secret, afterAuth = listOf(welcome)))
        val literal = server.socketAddress.address.hostAddress!!
        assertTrue("need two spellings of the host", literal != server.hostName)
        store.mac.value = paired().copy(otherHosts = listOf(literal))
        val connection = connection()
        connection.start()
        connection.hold("test")
        // No backoff wait between the two hosts: well under the first 1 s step.
        withTimeout(900) { connection.state.first { it is ConnectionState.Connected } }
        assertEquals(2, server.requestCount)
    }

    @Test
    fun movedMacKeepsTheOldHost() = runBlocking<Unit> {
        store.mac.value = paired().copy(host = "mac.tail1234.ts.net")
        store.updateAddress("srv", "192.168.1.9", 47822)
        assertEquals("192.168.1.9", store.mac.value!!.host)
        assertEquals(listOf("mac.tail1234.ts.net"), store.mac.value!!.otherHosts)
    }

    @Test
    fun hostListMergeAndOrder() {
        assertEquals(listOf("b", "a"), HostList.merge("p", old = listOf("a", "p"), new = listOf("b", " ", "a")))
        assertEquals(HostList.MAX_OTHER_HOSTS, HostList.merge("p", emptyList(), (1..10).map { "h$it" }).size)
        assertEquals(listOf("p", "a", "b"), HostList.candidates("p", listOf("a", "b"), lastGood = null))
        assertEquals(listOf("b", "p", "a"), HostList.candidates("p", listOf("a", "b"), lastGood = "b"))
        assertEquals(listOf("p", "a"), HostList.candidates("p", listOf("a"), lastGood = "gone"))
    }

    @Test
    fun backoffSteps() {
        assertEquals(1_000L, Backoff.delayMillis(0))
        assertEquals(30_000L, Backoff.delayMillis(5))
        assertEquals(30_000L, Backoff.delayMillis(50))
    }
}

private class FakeStore : PairingRepository {
    val mac = MutableStateFlow<PairedMac?>(null)
    override val pairedMac = mac

    override suspend fun savePairing(mac: PairedMac) {
        this.mac.value = mac
    }

    override suspend fun updateAddress(serverId: String, host: String, port: Int) {
        mac.value = mac.value?.let { it.copy(host = host, port = port, otherHosts = HostList.merge(host, it.otherHosts, listOf(it.host))) }
    }

    override suspend fun addHosts(serverId: String, hosts: List<String>) {
        mac.value = mac.value?.let { it.copy(otherHosts = HostList.merge(it.host, it.otherHosts, hosts)) }
    }

    override suspend fun updateName(name: String) {
        mac.value = mac.value?.copy(name = name)
    }

    override suspend fun forgetMac() {
        mac.value = null
    }
}
