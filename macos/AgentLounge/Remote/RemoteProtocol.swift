import Foundation

/// Phone protocol v2 (PLAN §10). WebSocket on the LAN listener. Crypto: `PhoneCrypto`.
///
/// Clear-text JSON (text frames), first phone message within `RemoteProtocol.authTimeout`:
/// - `{"type":"pair","v":2,"device":"Pixel 9","pub":"…","proof":"…"}` → `{"type":"paired","pub":"…","box":"…"}`, close.
/// - `{"type":"hello","v":2,"deviceId":"…","nonce":"…"}` → `{"type":"challenge","nonce":"…"}`.
/// - `error` (badMessage, badCode, noPairing, badToken), then close.
/// Encrypted JSON (binary frames, after `challenge`):
/// - phone `{"type":"auth"}` first → Mac `welcome` + `snapshot`.
/// - phone `{"type":"decide","requestId":"…","allow":true}`: answer a Claude permission request.
/// - phone `{"type":"prompt","cardId":"…","text":"…"}`: type a prompt into the session's terminal (Ghostty).
/// - Mac `snapshot` (after each change of cards or plan usage, throttled; `usage` added later, optional), `alert`, `result` (of a prompt), `error` (revoked).
nonisolated enum RemoteProtocol {
    static let version = 2
    static let serviceType = "_agentlounge._tcp"
    /// Unauthenticated connections are closed after this time.
    static let authTimeout: TimeInterval = 10
    /// Largest accepted phone message.
    static let maxMessageBytes = 16 * 1024
    /// Last assistant message is cut to this length.
    static let maxMessageLength = 2000
}

/// Phone → Mac.
nonisolated struct ClientMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case pair
        case hello
        case auth
        case decide
        case prompt
    }

    var type: Kind
    var v: Int?
    /// pair
    var device: String?
    var pub: String?
    var proof: String?
    /// hello
    var deviceId: String?
    var nonce: String?
    /// decide
    var requestId: String?
    var allow: Bool?
    /// prompt
    var cardId: String?
    var text: String?
}

/// Mac → phone. One flat struct: the phone decodes `type` first.
nonisolated struct ServerMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case paired
        case challenge
        case welcome
        case snapshot
        case alert
        case result
        case error
    }

    enum ErrorCode: String, Codable, Sendable {
        case badMessage
        case badCode
        case noPairing
        case badToken
        case authTimeout
        case revoked
    }

    var type: Kind
    var v: Int = RemoteProtocol.version
    /// paired: Mac public key and the sealed `PairedBox`.
    var pub: String? = nil
    var box: String? = nil
    /// challenge
    var nonce: String? = nil
    /// welcome: id of this phone on the Mac.
    var deviceId: String? = nil
    /// welcome: Mac name.
    var server: String? = nil
    /// welcome: stable Mac id, also in the Bonjour TXT record (`id`).
    var serverId: String? = nil
    /// snapshot
    var sessions: [RemoteCard]? = nil
    /// snapshot: plan usage per agent (`AgentUsage`). Nil when the usage bar is off.
    var usage: [AgentUsage]? = nil
    var sentAt: Date? = nil
    /// alert
    var alert: RemoteAlert? = nil
    /// result (prompt): ok, or the reason it failed.
    var cardId: String? = nil
    var ok: Bool? = nil
    var reason: String? = nil
    /// error
    var error: ErrorCode? = nil

    static func failure(_ code: ErrorCode) -> ServerMessage {
        ServerMessage(type: .error, error: code)
    }
}

/// Read-only card for the phone. A stable subset of `AgentSession` (no PIDs, tty, host process data).
nonisolated struct RemoteCard: Codable, Equatable, Sendable {
    struct Progress: Codable, Equatable, Sendable {
        var done: Int
        var total: Int
        var label: String?
    }

    struct TaskItem: Codable, Equatable, Sendable {
        var subject: String
        var activeForm: String?
        var status: AgentTask.Status
    }

    struct Context: Codable, Equatable, Sendable {
        var usedTokens: Int
        var limitTokens: Int
    }

    var id: String
    var agent: AgentKind
    var host: String
    var state: SessionState
    var title: String
    var project: String
    var subtitle: String
    var activity: String?
    var attention: String?
    var progress: Progress?
    var tasks: [TaskItem]
    var model: String?
    var effort: String?
    var permissionMode: String?
    var gitBranch: String?
    var cwd: String
    var startedAt: Date
    var lastEventAt: Date
    var subagentCount: Int
    var context: Context?
    var lastMessage: String?
    /// Open permission request that the phone may answer.
    var approval: RemoteApproval?
    /// The phone may type a prompt (Ghostty session with a known tty).
    var canPrompt: Bool
}

nonisolated struct RemoteApproval: Codable, Equatable, Sendable {
    var id: String
    var tool: String
    var title: String
    var detail: String?
}

nonisolated struct RemoteAlert: Codable, Equatable, Sendable {
    var kind: AlertKind
    var cardId: String
    var title: String
    var message: String
    /// Needs input with an open permission request: the phone can offer Allow / Deny.
    var approval: RemoteApproval?
}

extension RemoteApproval {
    init(_ approval: PendingApproval) {
        id = approval.id
        tool = approval.toolName
        title = approval.title
        detail = approval.detail
    }
}

extension RemoteCard {
    init(_ session: AgentSession, approval: PendingApproval? = nil) {
        self.approval = approval.map(RemoteApproval.init)
        canPrompt = PromptPlan.canPrompt(session)
        id = session.id
        agent = session.agent
        host = session.hostBadgeText
        state = session.state
        title = session.displayTitle
        project = session.projectName
        subtitle = session.subtitle
        activity = session.activity
        attention = session.attention
        progress = session.progress.map { Progress(done: $0.done, total: $0.total, label: $0.label) }
        tasks = session.tasks.map { TaskItem(subject: $0.subject, activeForm: $0.activeForm, status: $0.status) }
        model = session.model
        effort = session.effort
        permissionMode = session.permissionMode
        gitBranch = session.gitBranch
        cwd = session.cwd
        startedAt = session.startedAt
        lastEventAt = session.lastEventAt
        subagentCount = session.subagentCount
        context = session.context.map { Context(usedTokens: $0.usedTokens, limitTokens: $0.limitTokens) }
        lastMessage = session.lastAssistantMessage.map { text in
            text.count > RemoteProtocol.maxMessageLength
                ? String(text.prefix(RemoteProtocol.maxMessageLength)) + "…"
                : text
        }
    }
}

extension RemoteAlert {
    init(_ kind: AlertKind, session: AgentSession, approval: PendingApproval? = nil) {
        self.kind = kind
        self.approval = kind == .needsInput ? approval.map(RemoteApproval.init) : nil
        cardId = session.id
        title = session.displayTitle
        message = AlertRule.message(for: kind, session: session)
    }
}

nonisolated enum RemoteCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
