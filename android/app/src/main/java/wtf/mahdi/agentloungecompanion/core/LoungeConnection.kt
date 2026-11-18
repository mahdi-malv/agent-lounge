package wtf.mahdi.agentloungecompanion.core

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import wtf.mahdi.agentloungecompanion.data.PairedMac
import wtf.mahdi.agentloungecompanion.net.DiscoveredMac
import wtf.mahdi.agentloungecompanion.net.LoungeSockets
import wtf.mahdi.agentloungecompanion.net.SocketEvent
import wtf.mahdi.agentloungecompanion.protocol.AgentUsage
import wtf.mahdi.agentloungecompanion.protocol.ErrorCode
import wtf.mahdi.agentloungecompanion.protocol.FrameOpener
import wtf.mahdi.agentloungecompanion.protocol.FrameSealer
import wtf.mahdi.agentloungecompanion.protocol.PhoneCrypto
import wtf.mahdi.agentloungecompanion.protocol.unbase64
import java.security.interfaces.ECPublicKey
import wtf.mahdi.agentloungecompanion.protocol.Incoming
import wtf.mahdi.agentloungecompanion.protocol.LoungeProtocol
import wtf.mahdi.agentloungecompanion.protocol.RemoteAlert
import wtf.mahdi.agentloungecompanion.protocol.RemoteCard

/** Pairing storage, so tests can use a fake. Implemented by `LoungeStore`. */
interface PairingRepository {
    val pairedMac: Flow<PairedMac?>
    suspend fun savePairing(mac: PairedMac)
    suspend fun updateAddress(serverId: String, host: String, port: Int)
    suspend fun updateName(name: String)
    suspend fun forgetMac()
}

/** Finds the paired Mac's new address. Implemented by `MacDiscovery`. */
fun interface MacFinder {
    suspend fun find(serverId: String, timeoutMillis: Long): DiscoveredMac?
}

sealed interface ConnectionState {
    data object NotPaired : ConnectionState
    /** Paired, but nobody needs the connection (app in background, no background alerts). */
    data object Paused : ConnectionState
    data class Connecting(val attempt: Int) : ConnectionState
    data class Connected(val server: String) : ConnectionState
    data class Waiting(val retryAtMillis: Long, val reason: String) : ConnectionState
}

sealed interface PairOutcome {
    data object Success : PairOutcome
    data class Refused(val code: ErrorCode) : PairOutcome
    data class Failed(val reason: String) : PairOutcome
}

/** Retry delays after a lost or failed connection. */
object Backoff {
    private val steps = longArrayOf(1_000, 2_000, 4_000, 8_000, 15_000, 30_000)

    fun delayMillis(attempt: Int): Long = steps[attempt.coerceIn(0, steps.lastIndex)]
}

/**
 * Keeps one WebSocket to the paired Mac while someone holds the connection ([hold]): the visible
 * UI and the background service. Reconnects with [Backoff]; after two failures it looks for the
 * Mac's new address with mDNS.
 */
class LoungeConnection(
    private val store: PairingRepository,
    private val finder: MacFinder,
    private val sockets: LoungeSockets,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.NotPaired)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _cards = MutableStateFlow<List<RemoteCard>>(emptyList())
    /** Cards of the last snapshot. Kept while offline (shown as stale). */
    val cards: StateFlow<List<RemoteCard>> = _cards.asStateFlow()

    private val _alerts = MutableSharedFlow<RemoteAlert>(extraBufferCapacity = 32)
    val alerts: SharedFlow<RemoteAlert> = _alerts.asSharedFlow()

    private val _usage = MutableStateFlow<List<AgentUsage>>(emptyList())
    /** Plan usage of the last snapshot. */
    val usage: StateFlow<List<AgentUsage>> = _usage.asStateFlow()

    private val _pairingLost = MutableStateFlow<ErrorCode?>(null)
    /** Set when the Mac refused the token (phone removed on the Mac). Cleared by a new pairing. */
    val pairingLost: StateFlow<ErrorCode?> = _pairingLost.asStateFlow()

    private val _sentDecisions = MutableStateFlow<Set<String>>(emptySet())
    /** Requests this phone answered; hidden until the next snapshot drops them. */
    val sentDecisions: StateFlow<Set<String>> = _sentDecisions.asStateFlow()

    private val _promptResults = MutableSharedFlow<Incoming.Result>(extraBufferCapacity = 8)
    /** Answers of the Mac to prompts sent with [prompt]. */
    val promptResults: SharedFlow<Incoming.Result> = _promptResults.asSharedFlow()

    /** Encrypts and sends a JSON message on the authenticated socket. Null while not connected. */
    @Volatile private var sender: ((String) -> Boolean)? = null

    private val holders = MutableStateFlow<Set<String>>(emptySet())
    private val retryNow = Channel<Unit>(Channel.CONFLATED)

    fun start() {
        scope.launch {
            // A name change alone must not reconnect.
            val target = store.pairedMac.distinctUntilChanged { a, b -> a?.copy(name = "") == b?.copy(name = "") }
            combine(target, holders.map { it.isNotEmpty() }.distinctUntilChanged()) { mac, wanted -> mac to wanted }
                .collectLatest { (mac, wanted) ->
                    when {
                        mac == null -> {
                            _state.value = ConnectionState.NotPaired
                            _cards.value = emptyList()
                        }
                        !wanted -> _state.value = ConnectionState.Paused
                        else -> runLoop(mac)
                    }
                }
        }
    }

    fun hold(key: String) = holders.update { it + key }

    fun release(key: String) = holders.update { it - key }

    /** Skip the wait before the next attempt. */
    fun retry() {
        retryNow.trySend(Unit)
    }

    /** Answers a permission request. False when not connected. */
    fun decide(requestId: String, allow: Boolean): Boolean {
        val send = sender ?: return false
        val sent = send(LoungeProtocol.decide(requestId, allow))
        if (sent) _sentDecisions.update { it + requestId }
        return sent
    }

    /** Types [text] into the card's terminal on the Mac. False when not connected. */
    fun prompt(cardId: String, text: String): Boolean = sender?.invoke(LoungeProtocol.prompt(cardId, text)) ?: false

    suspend fun forget() {
        store.forgetMac()
    }

    /**
     * One pairing attempt (protocol v2): sends a public key and a proof of the code, opens the
     * Mac's box with the shared key. On success the pairing is saved and the normal connection starts.
     */
    suspend fun pair(host: String, port: Int, code: String, deviceName: String): PairOutcome {
        val keys = PhoneCrypto.newKeyPair()
        val publicKey = PhoneCrypto.x963(keys.public as ECPublicKey)
        val message = LoungeProtocol.pair(deviceName, publicKey, PhoneCrypto.proof(code, publicKey))
        val first = withTimeoutOrNull(PAIR_TIMEOUT_MILLIS) {
            sockets.open(host, port, message).first { it is SocketEvent.Ended || it is SocketEvent.Text }
        } ?: return PairOutcome.Failed("No answer from the Mac")
        if (first is SocketEvent.Ended) return PairOutcome.Failed(first.reason)
        return when (val incoming = LoungeProtocol.parse((first as SocketEvent.Text).text)) {
            is Incoming.Paired -> {
                val box = runCatching {
                    val key = PhoneCrypto.pairKey(keys.private, incoming.publicKey, code)
                    LoungeProtocol.parseBox(PhoneCrypto.openBox(incoming.box, key).decodeToString())
                }.getOrNull() ?: return PairOutcome.Failed("The Mac's answer could not be read")
                _pairingLost.value = null
                store.savePairing(
                    PairedMac(
                        serverId = box.serverId,
                        name = box.server,
                        host = host,
                        port = port,
                        secret = box.secret,
                        deviceId = box.deviceId,
                    ),
                )
                PairOutcome.Success
            }
            is Incoming.Error -> PairOutcome.Refused(incoming.code)
            else -> PairOutcome.Failed("Unexpected answer")
        }
    }

    private suspend fun runLoop(mac: PairedMac) {
        var attempt = 0
        while (true) {
            _state.value = ConnectionState.Connecting(attempt)
            val end = runSession(mac)
            if (end.refusal?.needsNewPairing == true) {
                Log.i(TAG, "Pairing refused: ${end.refusal}")
                _pairingLost.value = end.refusal
                store.forgetMac()
                return
            }
            if (end.wasConnected) attempt = 0
            val wait = Backoff.delayMillis(attempt)
            attempt++
            _state.value = ConnectionState.Waiting(clock() + wait, end.reason)
            if (attempt >= ADDRESS_CHECK_AFTER && mac.serverId.isNotEmpty()) {
                val found = runCatching { finder.find(mac.serverId, FIND_TIMEOUT_MILLIS) }.getOrNull()
                if (found != null && (found.host != mac.host || found.port != mac.port)) {
                    Log.i(TAG, "Mac moved to ${found.host}:${found.port}")
                    // The store change restarts this loop with the new address.
                    store.updateAddress(mac.serverId, found.host, found.port)
                    return
                }
            }
            withTimeoutOrNull(wait) { retryNow.receive() }
        }
    }

    private data class SessionEnd(val reason: String, val wasConnected: Boolean, val refusal: ErrorCode?)

    /** hello → challenge → encrypted auth, then encrypted messages until the socket ends. */
    private suspend fun runSession(mac: PairedMac): SessionEnd {
        var connected = false
        var refusal: ErrorCode? = null
        var reason = "Closed"
        val secret = mac.secret.unbase64() ?: return SessionEnd("Bad pairing data", false, ErrorCode.BAD_TOKEN)
        val phoneNonce = PhoneCrypto.randomBytes(PhoneCrypto.NONCE_LENGTH)
        var sendBinary: ((ByteArray) -> Boolean)? = null
        var sealer: FrameSealer? = null
        var opener: FrameOpener? = null

        fun handle(incoming: Incoming) {
            when (incoming) {
                is Incoming.Welcome -> {
                    connected = true
                    val seal = sealer
                    val send = sendBinary
                    if (seal != null && send != null) sender = { json -> send(seal.seal(json.encodeToByteArray())) }
                    _state.value = ConnectionState.Connected(incoming.server.ifEmpty { mac.name })
                    if (incoming.server.isNotEmpty() && incoming.server != mac.name) {
                        scope.launch { store.updateName(incoming.server) }
                    }
                }
                is Incoming.Snapshot -> {
                    _cards.value = incoming.sessions
                    _usage.value = incoming.usage
                    val open = incoming.sessions.mapNotNull { it.approval?.id }.toSet()
                    _sentDecisions.update { it intersect open }
                }
                is Incoming.Alert -> _alerts.tryEmit(incoming.alert)
                is Incoming.Result -> _promptResults.tryEmit(incoming)
                is Incoming.Error -> {
                    refusal = incoming.code
                    reason = "Refused: ${incoming.code.wire}"
                }
                is Incoming.Paired, is Incoming.Challenge, Incoming.Unknown -> Unit
            }
        }

        try {
            sockets.open(mac.host, mac.port, LoungeProtocol.hello(mac.deviceId, phoneNonce)).collect { event ->
                when (event) {
                    is SocketEvent.Opened -> sendBinary = event.sendBinary
                    is SocketEvent.Ended -> reason = event.reason
                    is SocketEvent.Text -> when (val incoming = LoungeProtocol.parse(event.text)) {
                        is Incoming.Challenge -> {
                            val (phoneToMac, macToPhone) = PhoneCrypto.sessionKeys(secret, phoneNonce, incoming.nonce)
                            val seal = FrameSealer(phoneToMac).also { sealer = it }
                            opener = FrameOpener(macToPhone)
                            sendBinary?.invoke(seal.seal(LoungeProtocol.auth().encodeToByteArray()))
                        }
                        // Clear text after the challenge is only an error before auth.
                        is Incoming.Error -> handle(incoming)
                        else -> Unit
                    }
                    is SocketEvent.Binary -> {
                        val plain = runCatching { opener?.open(event.bytes) }.getOrNull()
                        if (plain == null) {
                            reason = "Bad encrypted frame"
                            throw SessionAbort()
                        }
                        handle(LoungeProtocol.parse(plain.decodeToString()))
                    }
                }
            }
        } catch (_: SessionAbort) {
            // Collection stopped: the socket is closed by the flow.
        } finally {
            sender = null
        }
        return SessionEnd(reason, connected, refusal)
    }

    private class SessionAbort : Exception()

    private companion object {
        const val TAG = "LoungeConnection"
        const val PAIR_TIMEOUT_MILLIS = 10_000L
        const val FIND_TIMEOUT_MILLIS = 4_000L
        const val ADDRESS_CHECK_AFTER = 2
    }
}
