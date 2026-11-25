import Foundation
import os

/// Routes:
/// - `POST /events`: hook envelope → adapter → store. With header `X-Lounge-Wait: approval` (Claude
///   PermissionRequest), the answer may be held until a phone decides (`ApprovalCenter`).
/// - `GET /health`: "ok".
/// - `GET /debug/sessions`: current cards as JSON (dev aid).
/// - `GET /debug/events`: last 50 hook payloads, long strings cut (dev aid).
/// - `POST /debug/focus`: body = card id; same as a click on ↗ (dev aid).
/// - `GET /debug/hooks`: hook install status per agent (dev aid).
/// - `GET /debug/remote`: phone access status (dev aid).
/// - `POST /debug/pair-code`: starts phone pairing, returns the code (Debug builds only).
final class EventRouter {
    /// Called after each applied event; `createdCard` is true for a new card.
    var onEventApplied: ((AgentEvent, _ createdCard: Bool) -> Void)?
    /// Called after each applied event with the card state before it (nil = new card).
    var onStateChange: ((AgentEvent, _ before: SessionState?) -> Void)?
    /// Hook install status per agent, for `/debug/hooks`.
    var hookStatus: (() -> [String: String])?
    /// Phone access status, for `/debug/remote`.
    var remoteStatus: (() -> [String: String])?
    /// Starts pairing and returns the code, for `/debug/pair-code`.
    var startPairing: (() -> String?)?

    private let store: SessionStore
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Events")

    init(store: SessionStore) {
        self.store = store
    }

    /// Set by the app. Nil = never hold approval requests.
    var approvals: ApprovalCenter?

    func handle(_ request: HTTPRequest, responder: HTTPResponder) {
        if request.method == "POST", request.path == "/events" {
            handleEvent(request.body, wantsApproval: request.headers["x-lounge-wait"] == "approval", responder: responder)
        } else {
            responder.respond(handle(request))
        }
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .text("ok")
        case ("GET", "/debug/sessions"):
            guard let data = try? encoder.encode(store.sessions) else { return HTTPResponse(status: 500) }
            return .json(data)
        case ("GET", "/debug/events"):
            guard let data = try? encoder.encode(recentPayloads) else { return HTTPResponse(status: 500) }
            return .json(data)
        case ("GET", "/debug/hooks"):
            guard let data = try? encoder.encode(hookStatus?() ?? [:]) else { return HTTPResponse(status: 500) }
            return .json(data)
        case ("GET", "/debug/remote"):
            guard let data = try? encoder.encode(remoteStatus?() ?? [:]) else { return HTTPResponse(status: 500) }
            return .json(data)
        #if DEBUG
        case ("POST", "/debug/pair-code"):
            guard let code = startPairing?() else { return .notFound }
            return .text(code)
        #endif
        case ("POST", "/debug/focus"):
            let id = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard store.session(id) != nil else { return .notFound }
            store.focus(id)
            return .noContent
        default:
            return .notFound
        }
    }

    private func handleEvent(_ body: Data, wantsApproval: Bool, responder: HTTPResponder) {
        let envelope: HookEnvelope
        do {
            envelope = try decoder.decode(HookEnvelope.self, from: body)
        } catch {
            logger.error("Bad envelope: \(error.localizedDescription, privacy: .public)")
            responder.respond(.badRequest)
            return
        }

        let event: AgentEvent?
        switch envelope.source {
        case "claude":
            event = ClaudeAdapter.event(from: envelope, receivedAt: .now)
        case "codex":
            event = CodexAdapter.event(from: envelope, receivedAt: .now)
        case "antigravity", "agy":
            event = AntigravityAdapter.event(from: envelope, receivedAt: .now)
        default:
            event = nil
        }
        guard let event else {
            logger.info("Ignored event from source \(envelope.source, privacy: .public)")
            responder.respond(.accepted)
            return
        }

        logger.info("\(event.cardID, privacy: .public) \(event.kind.logDescription, privacy: .public)")
        remember(envelope.payload)
        approvals?.eventArrived(event)
        // Hold before the store applies the event: the phone alert then carries the request.
        var held = false
        if wantsApproval, case .permissionRequest(let tool) = event.kind, let approvals {
            held = approvals.hold(event, tool: tool, responder: responder)
        }
        let before = store.session(event.cardID)?.state
        let createdCard = store.apply(event)
        onEventApplied?(event, createdCard)
        onStateChange?(event, before)
        if !held { responder.respond(.noContent) }
    }

    // MARK: - Recent payloads (dev aid)

    private var recentPayloads: [JSONValue] = []
    private let recentLimit = 50

    private func remember(_ payload: JSONValue) {
        recentPayloads.append(Self.trimmed(payload))
        if recentPayloads.count > recentLimit {
            recentPayloads.removeFirst(recentPayloads.count - recentLimit)
        }
    }

    /// Cuts long strings (file contents, prompts) so the buffer stays small.
    private static func trimmed(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text) where text.count > 300: .string(String(text.prefix(300)) + "…")
        case .array(let items): .array(items.map(trimmed))
        case .object(let object): .object(object.mapValues(trimmed))
        default: value
        }
    }
}
