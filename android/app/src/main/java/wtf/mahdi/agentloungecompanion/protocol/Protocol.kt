package wtf.mahdi.agentloungecompanion.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.time.ExperimentalTime
import kotlin.time.Instant

/**
 * Agent Lounge phone protocol v2 (Mac repo: docs/PLAN.md §10, AgentLounge/Remote/RemoteProtocol.swift).
 * Clear-text JSON until the handshake (`pair`, `hello` / `challenge`), then JSON in AES-GCM binary
 * frames ([PhoneCrypto]).
 */
object LoungeProtocol {
    const val VERSION = 2
    const val SERVICE_TYPE = "_agentlounge._tcp"
    const val DEFAULT_PORT = 47822

    val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        explicitNulls = false
        encodeDefaults = true
    }

    private fun encode(message: ClientMessage) = json.encodeToString(ClientMessage.serializer(), message)

    /** [publicKey] = X9.63, [proof] = HMAC(code, publicKey). The code itself is not sent. */
    fun pair(device: String, publicKey: ByteArray, proof: ByteArray): String =
        encode(ClientMessage(type = "pair", v = VERSION, device = device, pub = publicKey.base64(), proof = proof.base64()))

    fun hello(deviceId: String, nonce: ByteArray): String =
        encode(ClientMessage(type = "hello", v = VERSION, deviceId = deviceId, nonce = nonce.base64()))

    /** First encrypted frame: proves the session key. */
    fun auth(): String = encode(ClientMessage(type = "auth"))

    /** Answer to a Claude permission request (`RemoteCard.approval`). */
    fun decide(requestId: String, allow: Boolean): String =
        encode(ClientMessage(type = "decide", requestId = requestId, allow = allow))

    /** Text typed into the session's terminal on the Mac (Ghostty), followed by Enter. */
    fun prompt(cardId: String, text: String): String =
        encode(ClientMessage(type = "prompt", cardId = cardId, text = text))

    /** Parses one Mac message (clear or decrypted). Unknown or broken messages give [Incoming.Unknown]. */
    fun parse(text: String): Incoming {
        val message = runCatching { json.decodeFromString(ServerMessage.serializer(), text) }
            .getOrElse { return Incoming.Unknown }
        return when (message.type) {
            "paired" -> {
                val pub = message.pub?.unbase64() ?: return Incoming.Unknown
                val box = message.box?.unbase64() ?: return Incoming.Unknown
                Incoming.Paired(pub, box)
            }
            "challenge" -> message.nonce?.unbase64()?.let { Incoming.Challenge(it) } ?: Incoming.Unknown
            "welcome" -> Incoming.Welcome(
                deviceId = message.deviceId.orEmpty(),
                server = message.server.orEmpty(),
                serverId = message.serverId.orEmpty(),
            )
            "snapshot" -> Incoming.Snapshot(message.sessions.orEmpty(), message.usage.orEmpty())
            "alert" -> message.alert?.let { Incoming.Alert(it) } ?: Incoming.Unknown
            "result" -> Incoming.Result(message.cardId.orEmpty(), message.ok == true, message.reason)
            "error" -> Incoming.Error(ErrorCode.from(message.error))
            else -> Incoming.Unknown
        }
    }

    fun parseBox(text: String): PairedBox? = runCatching { json.decodeFromString(PairedBox.serializer(), text) }.getOrNull()

    /** ISO 8601 → epoch millis. 0 when the text cannot be parsed. */
    @OptIn(ExperimentalTime::class)
    fun epochMillis(iso: String?): Long =
        iso?.let { runCatching { Instant.parse(it).toEpochMilliseconds() }.getOrNull() } ?: 0L
}

@OptIn(ExperimentalEncodingApi::class)
fun ByteArray.base64(): String = Base64.encode(this)

@OptIn(ExperimentalEncodingApi::class)
fun String.unbase64(): ByteArray? = runCatching { Base64.decode(this) }.getOrNull()

sealed interface Incoming {
    /** Mac public key and the sealed [PairedBox]. */
    class Paired(val publicKey: ByteArray, val box: ByteArray) : Incoming
    class Challenge(val nonce: ByteArray) : Incoming
    data class Welcome(val deviceId: String, val server: String, val serverId: String) : Incoming
    /** [usage] is empty when the Mac sends none (older Mac or usage bar off). */
    data class Snapshot(val sessions: List<RemoteCard>, val usage: List<AgentUsage> = emptyList()) : Incoming
    data class Alert(val alert: RemoteAlert) : Incoming
    /** Answer to a prompt: [reason] is set when it failed. */
    data class Result(val cardId: String, val ok: Boolean, val reason: String?) : Incoming
    data class Error(val code: ErrorCode) : Incoming
    data object Unknown : Incoming
}

/** Plaintext of the `paired` box. [secret] is base64. */
@Serializable
data class PairedBox(val secret: String, val deviceId: String, val server: String = "", val serverId: String = "")

enum class ErrorCode(val wire: String) {
    BAD_MESSAGE("badMessage"),
    BAD_CODE("badCode"),
    NO_PAIRING("noPairing"),
    BAD_TOKEN("badToken"),
    AUTH_TIMEOUT("authTimeout"),
    REVOKED("revoked"),
    OTHER("");

    /** The Mac no longer knows this phone: it must pair again. */
    val needsNewPairing: Boolean get() = this == BAD_TOKEN || this == REVOKED

    companion object {
        fun from(wire: String?): ErrorCode = entries.firstOrNull { it.wire == wire && it != OTHER } ?: OTHER
    }
}

@Serializable
internal data class ClientMessage(
    val type: String,
    val v: Int? = null,
    val device: String? = null,
    val pub: String? = null,
    val proof: String? = null,
    val deviceId: String? = null,
    val nonce: String? = null,
    val requestId: String? = null,
    val allow: Boolean? = null,
    val cardId: String? = null,
    val text: String? = null,
)

@Serializable
internal data class ServerMessage(
    val type: String,
    val v: Int = LoungeProtocol.VERSION,
    val pub: String? = null,
    val box: String? = null,
    val nonce: String? = null,
    val deviceId: String? = null,
    val server: String? = null,
    val serverId: String? = null,
    val sessions: List<RemoteCard>? = null,
    val usage: List<AgentUsage>? = null,
    val sentAt: String? = null,
    val alert: RemoteAlert? = null,
    val cardId: String? = null,
    val ok: Boolean? = null,
    val reason: String? = null,
    val error: String? = null,
)

@Serializable
enum class SessionState {
    @SerialName("running") RUNNING,
    @SerialName("needsInput") NEEDS_INPUT,
    @SerialName("idle") IDLE,
    @SerialName("error") ERROR,
}

@Serializable
enum class AgentKind {
    @SerialName("claude") CLAUDE,
    @SerialName("codex") CODEX,
}

@Serializable
enum class TaskStatus {
    @SerialName("pending") PENDING,
    @SerialName("inProgress") IN_PROGRESS,
    @SerialName("completed") COMPLETED,
}

@Serializable
enum class AlertKind {
    @SerialName("needsInput") NEEDS_INPUT,
    @SerialName("done") DONE,
    @SerialName("error") ERROR,
}

/** Read-only card, same fields as the Mac `RemoteCard`. Dates are ISO 8601 text. */
@Serializable
data class RemoteCard(
    val id: String,
    val agent: AgentKind = AgentKind.CLAUDE,
    val host: String = "",
    val state: SessionState = SessionState.RUNNING,
    val title: String = "",
    val project: String = "",
    val subtitle: String = "",
    val activity: String? = null,
    val attention: String? = null,
    val progress: Progress? = null,
    val tasks: List<TaskItem> = emptyList(),
    val model: String? = null,
    val effort: String? = null,
    val permissionMode: String? = null,
    val gitBranch: String? = null,
    val cwd: String = "",
    val startedAt: String? = null,
    val lastEventAt: String? = null,
    val subagentCount: Int = 0,
    /** Running subagents, oldest first. Empty from a Mac app without subagent rows. */
    val subagents: List<Subagent> = emptyList(),
    /** The Mac's planet for this card. Null from an older Mac app: the phone then picks one from the project. */
    val planetSeed: String? = null,
    val planetIdentity: Int? = null,
    val context: Context? = null,
    val lastMessage: String? = null,
    /** Open permission request this phone may answer. */
    val approval: RemoteApproval? = null,
    /** The Mac can type a prompt into this session (Ghostty). */
    val canPrompt: Boolean = false,
) {
    @Serializable
    data class Progress(val done: Int, val total: Int, val label: String? = null)

    @Serializable
    data class TaskItem(
        val subject: String,
        val activeForm: String? = null,
        val status: TaskStatus = TaskStatus.PENDING,
    )

    @Serializable
    data class Context(val usedTokens: Int, val limitTokens: Int)

    @Serializable
    data class Subagent(val id: String, val name: String = "", val activity: String? = null)
}

@Serializable
data class RemoteAlert(
    val kind: AlertKind = AlertKind.NEEDS_INPUT,
    val cardId: String,
    val title: String = "",
    val message: String = "",
    val approval: RemoteApproval? = null,
)

/** A Claude permission dialog on the Mac. `title` is short ("Running npm test"), `detail` the full command. */
@Serializable
data class RemoteApproval(
    val id: String,
    val tool: String = "",
    val title: String = "",
    val detail: String? = null,
)

/** Plan usage of one agent (Mac `AgentUsage`). Dates are ISO 8601 text. */
@Serializable
data class AgentUsage(
    val agent: AgentKind = AgentKind.CLAUDE,
    val plan: String? = null,
    val windows: List<UsageWindow> = emptyList(),
    val updatedAt: String? = null,
    /** Short reason when there are no numbers ("Not signed in to Claude Code"). */
    val problem: String? = null,
)

/** One limit window, e.g. "5h" at 12 % used. */
@Serializable
data class UsageWindow(
    val label: String = "",
    /** 0..100. */
    val usedPercent: Double = 0.0,
    val resetsAt: String? = null,
)
