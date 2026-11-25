import Foundation

/// Hook entries in an agent's config file (PLAN §7). Pure edits on `OrderedJSON`, so tests need no files.
///
/// - Claude (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) use `.wrapped`:
///   `{"hooks": {"<Event>": [{"matcher": "*", "hooks": [{"type": "command", "command": …, "timeout": 5}]}]}}`.
/// - Antigravity (`~/.gemini/config/hooks.json`) uses `.named("agent-lounge")`:
///   `{"agent-lounge": {"SessionStart": [handler], "PreToolUse": [{"matcher": "*", "hooks": [handler]}], …}}`.
/// Our handlers are found by the command text (it names `lounge-hook`); other entries are never changed.
nonisolated struct HookConfig: Sendable {
    enum Shape: Equatable, Sendable {
        /// Claude / Codex: `{"hooks": {"<Event>": [{"matcher"?, "hooks": [handler]}]}}`.
        case wrapped
        /// Antigravity: `{"<name>": {"<Event>": [handler] | [{"matcher": "*", "hooks": [handler]}]}}`.
        case named(String)
    }

    let agent: AgentKind
    /// Events that get a hook. Tool events get `"matcher": "*"`.
    let events: [String]
    let toolEvents: Set<String>
    /// Events with another timeout than `timeoutSeconds`.
    var timeouts: [String: Int] = [:]
    var shape: Shape = .wrapped

    static let claude = HookConfig(
        agent: .claude,
        events: [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "TaskCreated",
            "TaskCompleted", "Stop", "StopFailure", "PreCompact", "PostCompact", "CwdChanged", "SessionEnd",
        ],
        toolEvents: ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"],
        // The hook waits for an answer from the phone (PLAN §12). Claude shows its dialog meanwhile.
        timeouts: ["PermissionRequest": approvalTimeoutSeconds]
    )

    static let codex = HookConfig(
        agent: .codex,
        events: [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
            "SubagentStart", "SubagentStop", "Stop", "Interrupt", "PreCompact", "PostCompact", "SessionEnd",
        ],
        toolEvents: ["PreToolUse", "PostToolUse", "PermissionRequest"]
    )

    static let antigravity = HookConfig(
        agent: .antigravity,
        events: ["SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"],
        toolEvents: ["PreToolUse", "PostToolUse"],
        shape: .named("agent-lounge")
    )

    static let timeoutSeconds = 5
    /// Longest wait for a phone answer. Keep below `HTTPConnection.holdLimit`.
    static let approvalTimeoutSeconds = 3_600

    func timeout(for event: String) -> Int {
        timeouts[event] ?? Self.timeoutSeconds
    }
    /// Claude Code env var that turns on the Task tools (progress bars, PLAN §2).
    static let todoToolsEnvKey = "CLAUDE_CODE_ENABLE_TODO_TOOLS"

    enum Status: Equatable, Sendable {
        case notInstalled
        /// All events have our handler with this exact command.
        case installed
        /// Some of our handlers exist, but not all, or with another command (e.g. the app moved).
        case outdated
    }

    /// `'<path>' <agent>`; the path is single-quoted for the shell.
    static func command(hookPath: String, agent: AgentKind) -> String {
        "'\(hookPath.replacingOccurrences(of: "'", with: "'\\''"))' \(agent.rawValue)"
    }

    static func isOurs(_ command: String) -> Bool {
        command.contains("lounge-hook")
    }

    // MARK: - Status

    func status(of config: OrderedJSON, command: String) -> Status {
        let ours = ourHandlersByEvent(config)
        guard !ours.isEmpty else { return .notInstalled }
        let complete = events.allSatisfy { ours[$0] == [Handler(command: command, timeout: timeout(for: $0))] }
            && ours.count == events.count
        return complete ? .installed : .outdated
    }

    private struct Handler: Equatable {
        var command: String
        var timeout: Int?
    }

    private var rootKey: String {
        switch shape {
        case .wrapped: "hooks"
        case .named(let name): name
        }
    }

    private func ourHandlersByEvent(_ config: OrderedJSON) -> [String: [Handler]] {
        var result: [String: [Handler]] = [:]
        for member in config[rootKey]?.members ?? [] {
            for item in member.value.arrayValue ?? [] {
                if let nested = item["hooks"]?.arrayValue {
                    for handler in nested {
                        if let command = handler["command"]?.stringValue, Self.isOurs(command) {
                            let timeout = handler["timeout"]?.numberText.flatMap { Int($0) }
                            result[member.key, default: []].append(Handler(command: command, timeout: timeout))
                        }
                    }
                } else if case .named = shape, let command = item["command"]?.stringValue, Self.isOurs(command) {
                    let timeout = item["timeout"]?.numberText.flatMap { Int($0) }
                    result[member.key, default: []].append(Handler(command: command, timeout: timeout))
                }
            }
        }
        return result
    }

    // MARK: - Edit

    /// Removes our handlers. Groups, events and `hooks` left empty by that are removed too.
    func uninstalled(_ config: OrderedJSON) -> OrderedJSON {
        stripped(config, keepKeys: false)
    }

    /// - Parameter keepKeys: keep emptied event keys and root key in place, so a new install
    ///   puts our handlers where they were (install twice = no change).
    private func stripped(_ config: OrderedJSON, keepKeys: Bool) -> OrderedJSON {
        guard let events = config[rootKey]?.members else { return config }
        var keptEvents: [OrderedJSON.Member] = []
        for event in events {
            guard let items = event.value.arrayValue else {
                keptEvents.append(event)
                continue
            }
            var keptItems: [OrderedJSON] = []
            for item in items {
                if let handlers = item["hooks"]?.arrayValue {
                    let kept = handlers.filter { handler in
                        !(handler["command"]?.stringValue.map(Self.isOurs) ?? false)
                    }
                    if kept.count == handlers.count {
                        keptItems.append(item)
                    } else if !kept.isEmpty {
                        var group = item
                        group["hooks"] = .array(kept)
                        keptItems.append(group)
                    }
                } else if case .named = shape, item["command"]?.stringValue.map(Self.isOurs) == true {
                    continue
                } else {
                    keptItems.append(item)
                }
            }
            if !keptItems.isEmpty || keepKeys {
                keptEvents.append(OrderedJSON.Member(key: event.key, value: .array(keptItems)))
            }
        }
        var result = config
        result[rootKey] = keptEvents.isEmpty && !keepKeys ? nil : .object(keptEvents)
        return result
    }

    /// Replaces our handlers with fresh ones for `command`. Other hooks stay as they are.
    func installed(_ config: OrderedJSON, command: String) -> OrderedJSON {
        var result = stripped(config, keepKeys: true)
        if case .object = result {} else { result = .emptyObject }
        var hooks = result[rootKey] ?? .emptyObject
        for event in events {
            let handler = OrderedJSON.object([
                .init(key: "type", value: .string("command")),
                .init(key: "command", value: .string(command)),
                .init(key: "timeout", value: .number(String(timeout(for: event)))),
            ])
            let entry: OrderedJSON
            if case .named = shape, !toolEvents.contains(event) {
                entry = handler
            } else {
                var group: [OrderedJSON.Member] = []
                if toolEvents.contains(event) { group.append(.init(key: "matcher", value: .string("*"))) }
                group.append(.init(key: "hooks", value: .array([handler])))
                entry = .object(group)
            }
            var items = hooks[event]?.arrayValue ?? []
            items.append(entry)
            hooks[event] = .array(items)
        }
        result[rootKey] = hooks
        return result
    }

    /// Claude only: sets the Task-tools env var when it is not set. Returns nil when nothing changed.
    static func withTodoTools(_ config: OrderedJSON) -> OrderedJSON? {
        guard config["env"]?[todoToolsEnvKey] == nil else { return nil }
        var result = config
        var env = result["env"] ?? .emptyObject
        env[todoToolsEnvKey] = .string("1")
        result["env"] = env
        return result
    }

    /// Claude only: removes the env var we added (only when it still has our value).
    static func withoutTodoTools(_ config: OrderedJSON) -> OrderedJSON {
        guard config["env"]?[todoToolsEnvKey] == .string("1") else { return config }
        var result = config
        var env = result["env"]!
        env[todoToolsEnvKey] = nil
        result["env"] = env.members?.isEmpty == true ? nil : env
        return result
    }
}
