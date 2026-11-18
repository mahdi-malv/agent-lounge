import Foundation
import Observation
import os

/// A Claude permission dialog that a paired phone can answer (PLAN §12).
nonisolated struct PendingApproval: Identifiable, Equatable, Sendable {
    let id: String
    let cardID: String
    /// Subagent that asked, nil for the main agent.
    let agentId: String?
    let toolName: String
    let toolInput: JSONValue?
    /// Short text, e.g. "Run rm -rf build" (from `ToolActivity`).
    let title: String
    /// Full command, file path or URL, cut to `maxDetail` characters.
    let detail: String?
    let createdAt: Date

    static let maxDetail = 600
}

/// Pure rules for approvals, so they can be unit tested.
nonisolated enum ApprovalRules {
    /// These tools need an answer in `updatedInput`, not a plain allow (Claude hooks docs).
    static let unsupportedTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static func canHold(_ tool: ToolCall) -> Bool {
        !unsupportedTools.contains(tool.name)
    }

    /// Hook stdout for a decision.
    static func hookOutput(allow: Bool) -> Data {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = "The user denied this from the phone (Agent Lounge)." }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
        ]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    /// Pending requests that `event` shows as answered on the Mac (or gone), for the same card.
    /// - A later tool event of the same agent: the dialog was answered and the agent moved on.
    /// - A turn or session end of the main agent: nothing of this card is still waiting.
    static func resolved(by event: AgentEvent, among pending: [PendingApproval]) -> [PendingApproval] {
        let same = pending.filter { $0.cardID == event.cardID }
        switch event.kind {
        case .preToolUse, .postToolUse, .postToolUseFailure:
            return same.filter { $0.agentId == event.agentId }
        case .userPromptSubmit, .stop, .stopFailure, .interrupt, .sessionEnd:
            return event.agentId == nil ? same : same.filter { $0.agentId == event.agentId }
        case .subagentStop:
            return same.filter { $0.agentId != nil && $0.agentId == event.agentId }
        default:
            return []
        }
    }

    static func detail(of tool: ToolCall) -> String? {
        let keys = ["command", "file_path", "notebook_path", "url", "path", "pattern", "query"]
        guard let text = keys.lazy.compactMap({ tool.input?[$0]?.stringValue }).first, !text.isEmpty else { return nil }
        return text.count > PendingApproval.maxDetail ? String(text.prefix(PendingApproval.maxDetail)) + "…" : text
    }
}

/// Holds `lounge-hook` requests for Claude permission dialogs until a phone answers, the dialog is
/// answered on the Mac, or the hook goes away. The Mac dialog shows at the same time (checked live),
/// so holding never blocks the user at the Mac.
@Observable
final class ApprovalCenter {
    private(set) var pending: [PendingApproval] = []

    @ObservationIgnored private var responders: [PendingApproval.ID: HTTPResponder] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Approvals")

    /// Set by the app: phone access on, approvals on, at least one paired phone.
    @ObservationIgnored var isEnabled: () -> Bool = { false }

    /// Keeps the request open when approvals are on. Returns false when the caller must answer now.
    func hold(_ event: AgentEvent, tool: ToolCall, responder: HTTPResponder) -> Bool {
        guard isEnabled(), event.agent == .claude, ApprovalRules.canHold(tool) else { return false }
        let approval = PendingApproval(
            id: UUID().uuidString,
            cardID: event.cardID,
            agentId: event.agentId,
            toolName: tool.name,
            toolInput: tool.input,
            title: ToolActivity.describe(tool),
            detail: ApprovalRules.detail(of: tool),
            createdAt: .now
        )
        responders[approval.id] = responder
        responder.onClientGone = { [weak self] in self?.drop(approval.id, reason: "hook gone") }
        pending.append(approval)
        logger.info("Holding \(approval.id, privacy: .public) for \(approval.cardID, privacy: .public): \(tool.name, privacy: .public)")
        return true
    }

    /// Answer from a phone. Returns false when the request is no longer open.
    @discardableResult
    func decide(_ id: PendingApproval.ID, allow: Bool, by device: String) -> Bool {
        guard let responder = responders.removeValue(forKey: id) else { return false }
        pending.removeAll { $0.id == id }
        logger.info("\(allow ? "Allow" : "Deny", privacy: .public) \(id, privacy: .public) from \(device, privacy: .public)")
        responder.respond(.json(ApprovalRules.hookOutput(allow: allow)))
        return true
    }

    /// Called for every hook event before the store applies it.
    func eventArrived(_ event: AgentEvent) {
        for approval in ApprovalRules.resolved(by: event, among: pending) {
            release(approval.id, reason: "answered on the Mac")
        }
    }

    /// Releases every open request without a decision (phone access turned off).
    func releaseAll() {
        pending.map(\.id).forEach { release($0, reason: "approvals off") }
    }

    func first(for cardID: String) -> PendingApproval? {
        pending.first { $0.cardID == cardID }
    }

    /// The hook gets no decision: Claude keeps its own dialog.
    private func release(_ id: PendingApproval.ID, reason: String) {
        let responder = responders.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        logger.info("Released \(id, privacy: .public): \(reason, privacy: .public)")
        responder?.respond(.noContent)
    }

    private func drop(_ id: PendingApproval.ID, reason: String) {
        responders[id] = nil
        pending.removeAll { $0.id == id }
        logger.info("Dropped \(id, privacy: .public): \(reason, privacy: .public)")
    }
}
