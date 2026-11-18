import Foundation

/// What `lounge-hook` POSTs to `/events`. Keep in sync with `LoungeHook/main.swift`.
nonisolated struct HookEnvelope: Decodable, Sendable {
    var v: Int
    /// "claude" or "codex" (first argument of `lounge-hook`).
    var source: String
    /// Unix time in seconds, set by the hook.
    var sentAt: Double?
    var host: HostInfo
    /// Hook stdin JSON, unchanged.
    var payload: JSONValue
}

/// Host facts collected by the hook from its env and process tree.
nonisolated struct HostInfo: Codable, Hashable, Sendable {
    var termProgram: String?
    var termProgramVersion: String?
    /// `__CFBundleIdentifier` inherited from the app that started the shell or agent.
    var bundleId: String?
    /// `CLAUDE_CODE_ENTRYPOINT`, e.g. "cli".
    var entrypoint: String?
    var cmuxSurfaceId: String?
    var cmuxWorkspaceId: String?
    var cmuxSocketPath: String?
    var cmuxClaudePid: String?
    var zedTerm: String?
    var termSessionId: String?
    var itermSessionId: String?
    /// Controlling terminal, e.g. "ttys012".
    var tty: String?
    /// Hook ancestors, nearest first: shell → agent → … → terminal app → launchd.
    var processes: [ProcessEntry]?

    init(
        termProgram: String? = nil,
        bundleId: String? = nil,
        entrypoint: String? = nil,
        cmuxSurfaceId: String? = nil,
        cmuxWorkspaceId: String? = nil,
        zedTerm: String? = nil,
        tty: String? = nil,
        processes: [ProcessEntry]? = nil
    ) {
        self.termProgram = termProgram
        self.bundleId = bundleId
        self.entrypoint = entrypoint
        self.cmuxSurfaceId = cmuxSurfaceId
        self.cmuxWorkspaceId = cmuxWorkspaceId
        self.zedTerm = zedTerm
        self.tty = tty
        self.processes = processes
    }
}

nonisolated struct ProcessEntry: Codable, Hashable, Sendable {
    var pid: Int32
    var ppid: Int32
    /// Kernel short name (`p_comm`, max 16 chars).
    var name: String
    /// Full executable path, when readable.
    var path: String?
    /// Controlling terminal, e.g. "ttys012".
    var tty: String?
}

nonisolated extension HostInfo {
    /// Env var names, same set as `hostEnvironmentKeys` in `LoungeHook/main.swift`.
    static var environmentKeys: [(WritableKeyPath<HostInfo, String?>, String)] { [
        (\.termProgram, "TERM_PROGRAM"),
        (\.termProgramVersion, "TERM_PROGRAM_VERSION"),
        (\.bundleId, "__CFBundleIdentifier"),
        (\.entrypoint, "CLAUDE_CODE_ENTRYPOINT"),
        (\.cmuxSurfaceId, "CMUX_SURFACE_ID"),
        (\.cmuxWorkspaceId, "CMUX_WORKSPACE_ID"),
        (\.cmuxSocketPath, "CMUX_SOCKET_PATH"),
        (\.cmuxClaudePid, "CMUX_CLAUDE_PID"),
        (\.zedTerm, "ZED_TERM"),
        (\.termSessionId, "TERM_SESSION_ID"),
        (\.itermSessionId, "ITERM_SESSION_ID"),
    ] }

    /// Host facts read from a running agent process (backfill), like the hook collects them.
    init(environment: [String: String], processes: [ProcessEntry]) {
        self.init(processes: processes)
        for (keyPath, name) in Self.environmentKeys {
            if let value = environment[name], !value.isEmpty {
                self[keyPath: keyPath] = value
            }
        }
        tty = processes.lazy.compactMap(\.tty).first
    }

    /// Host for the badge and the focus route.
    /// The process tree wins: env vars (`CMUX_*`, `__CFBundleIdentifier`) are inherited, so an app
    /// started from another app's shell (e.g. Zed opened from a cmux tab) carries stale values.
    var hostKind: HostKind {
        if let kind = Self.hostKind(processes: processes ?? []) { return kind }
        if zedTerm == "true" || termProgram == "zed" { return .zed }
        if cmuxSurfaceId != nil { return .cmux }
        if entrypoint == "claude-desktop" { return .claudeApp }
        if let name = Self.terminalName(termProgram: termProgram) { return .terminal(name) }
        switch bundleId {
        case "com.cmuxterm.app": return .cmux
        case "dev.zed.Zed": return .zed
        case "com.anthropic.claudefordesktop": return .claudeApp
        case "com.openai.codex": return .codexApp
        case "com.mitchellh.ghostty": return .terminal("Ghostty")
        default: return .unknown
        }
    }

    /// Nearest known host app in the ancestor chain, by bundle folder name (case-sensitive:
    /// Claude.app ships the CLI inside a lower-case `claude.app`, which is not a host;
    /// the Codex CLI binary sits in `CodexCLI.app`, also not a host).
    static func hostKind(processes: [ProcessEntry]) -> HostKind? {
        for entry in processes {
            guard let path = entry.path, let range = path.range(of: ".app/Contents/MacOS/") else { continue }
            let bundle = path[..<range.lowerBound].split(separator: "/").last.map(String.init) ?? ""
            switch bundle {
            case "cmux": return .cmux
            case "Zed", "Zed Preview": return .zed
            case "Claude": return .claudeApp
            case "ChatGPT", "Codex": return .codexApp
            case "Ghostty": return .terminal("Ghostty")
            case "Terminal": return .terminal("Terminal")
            case "iTerm", "iTerm2": return .terminal("iTerm")
            case "Warp", "WezTerm", "kitty", "Alacritty": return .terminal(bundle)
            case "Visual Studio Code": return .terminal("VS Code")
            case "Cursor": return .terminal("Cursor")
            default: continue
            }
        }
        return nil
    }

    /// PID of the agent process (`claude` / `codex`) in the hook's ancestor chain.
    func agentPID(for agent: AgentKind) -> Int32? {
        let name = agent.rawValue
        let match = processes?.first { entry in
            if entry.name == name { return true }
            guard let path = entry.path else { return false }
            // Native installs run e.g. ~/.local/share/claude/versions/2.1.327.
            return path.hasSuffix("/\(name)") || path.contains("/\(name)/versions/")
        }
        if let match { return match.pid }
        if agent == .claude, let pid = cmuxClaudePid.flatMap(Int32.init) { return pid }
        return nil
    }

    private static func terminalName(termProgram: String?) -> String? {
        guard let termProgram, !termProgram.isEmpty else { return nil }
        switch termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        case "vscode": return "VS Code"
        default: return termProgram
        }
    }
}

/// Any JSON value. Keeps the raw hook payload without a fixed schema.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var intValue: Int? {
        if case .number(let value) = self { Int(exactly: value.rounded()) } else { nil }
    }
}
