import AppKit
import os

/// Rules for a prompt typed on the phone (PLAN §12). Pure, so it can be unit tested.
nonisolated enum PromptPlan {
    static let maxLength = 4_000

    enum Plan: Equatable, Sendable {
        case ghostty(tty: String, text: String)
        case refused(String)
    }

    /// Ghostty sessions with a known tty. Other hosts have no safe way to type into one session.
    static func canPrompt(_ session: AgentSession) -> Bool {
        if case .ghostty = FocusRoute.route(for: session) { return true }
        return false
    }

    static func plan(for session: AgentSession?, text: String) -> Plan {
        guard let session else { return .refused("The session has ended.") }
        guard case .ghostty(let tty) = FocusRoute.route(for: session) else {
            return .refused("Prompts work only for sessions in Ghostty.")
        }
        // Text + Enter would answer the open dialog in the terminal.
        guard session.state != .needsInput else {
            return .refused("The agent waits for an answer in a dialog. Answer it first.")
        }
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return .refused("The prompt is empty.") }
        return .ghostty(tty: tty, text: cleaned)
    }

    /// No control characters except line breaks and tabs; no trailing blank lines; at most `maxLength`.
    static func clean(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.properties.generalCategory == .control)
        }
        let joined = String(String.UnicodeScalarView(kept)).replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxLength))
    }

    /// AppleScript string literal with escapes.
    static func literal(_ text: String) -> String {
        var result = "\""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }

    static func appleScript(tty: String, text: String) -> String {
        """
        tell application id "\(FocusRoute.ghosttyBundleId)"
            set t to first terminal whose tty is \(literal(tty))
            input text \(literal(text)) to t
            send key "enter" to t
        end tell
        """
    }
}

/// Types a phone prompt into the session's Ghostty terminal. Needs the Automation permission for Ghostty.
final class PromptService {
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Prompt")

    /// Returns nil on success, else a reason for the phone.
    func send(_ text: String, to session: AgentSession?) -> String? {
        switch PromptPlan.plan(for: session, text: text) {
        case .refused(let reason):
            return reason
        case .ghostty(let tty, let cleaned):
            guard tty.range(of: #"^/dev/tty[a-z0-9]+$"#, options: .regularExpression) != nil else {
                return "Unknown terminal."
            }
            var error: NSDictionary?
            NSAppleScript(source: PromptPlan.appleScript(tty: tty, text: cleaned))?.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                let message = error[NSAppleScript.errorMessage] as? String ?? ""
                logger.error("Ghostty input failed (\(number)): \(message, privacy: .public)")
                return number == -1743
                    ? "Agent Lounge may not control Ghostty. Allow it in System Settings → Privacy & Security → Automation."
                    : "Ghostty did not take the text (\(number))."
            }
            logger.info("Typed \(cleaned.count) characters into \(tty, privacy: .public)")
            return nil
        }
    }
}
