import Foundation

/// Facts from an agent transcript: Claude Code (`~/.claude/projects/<cwd>/<session>.jsonl`)
/// or Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread>.jsonl`).
nonisolated struct TranscriptSummary: Equatable, Sendable {
    var model: String?
    var effort: String?
    var permissionMode: String?
    var gitBranch: String?
    var aiTitle: String?
    var customTitle: String?
    /// Context in use after the last main-chain reply: input + cache tokens.
    var contextTokens: Int?
    var peakContextTokens = 0
    /// Context window size when the transcript states it (Codex). Claude: nil, see `ContextWindow`.
    var contextWindow: Int?
    var lastAssistantText: String?
    var lastStopReason: String?
    var lastRole: Role?
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var tasks = TaskBook()
    /// False when only the tail of a very large file was read.
    var isComplete = true

    enum Role: Sendable {
        case user
        case assistant
        case interrupt
    }

    /// Best guess of the card state, for sessions found by backfill.
    var inferredState: SessionState? {
        switch lastRole {
        case .assistant: lastStopReason == "end_turn" ? .idle : .running
        case .user: .running
        case .interrupt: .idle
        case nil: nil
        }
    }
}

/// Transcript format per agent. `TranscriptReader` keeps one parser per file.
nonisolated enum TranscriptFormat: Sendable {
    case claude
    case codex
    case antigravity

    init(_ agent: AgentKind) {
        switch agent {
        case .claude: self = .claude
        case .codex: self = .codex
        case .antigravity: self = .antigravity
        }
    }

    func makeParser(startsMidFile: Bool) -> any TranscriptParsing {
        switch self {
        case .claude: TranscriptParser(startsMidFile: startsMidFile)
        case .codex: CodexRolloutParser(startsMidFile: startsMidFile)
        case .antigravity: AntigravityTranscriptParser(startsMidFile: startsMidFile)
        }
    }
}

/// Incremental parser: feed bytes in any chunks.
nonisolated protocol TranscriptParsing: Sendable {
    var summary: TranscriptSummary { get }
    mutating func consume(_ data: Data)
}

/// Splits a byte stream into JSONL lines and keeps the partial last line.
nonisolated struct JSONLLineBuffer: Sendable {
    private var buffer = Data()
    /// Set when reading starts in the middle of a file: drop the first (partial) line.
    private var skipFirstLine: Bool

    init(startsMidFile: Bool) {
        skipFirstLine = startsMidFile
    }

    /// Complete, non-empty lines in `data` (plus the kept rest of the last call).
    mutating func lines(appending data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            if skipFirstLine {
                skipFirstLine = false
            } else if newline > lineStart {
                lines.append(buffer[lineStart..<newline])
            }
            lineStart = buffer.index(after: newline)
        }
        buffer = Data(buffer[lineStart...])
        return lines
    }
}

/// Incremental Claude Code JSONL parser.
nonisolated struct TranscriptParser: TranscriptParsing {
    private(set) var summary = TranscriptSummary()
    private var lineBuffer: JSONLLineBuffer
    /// TaskCreate inputs waiting for their result line (which carries the task id).
    private var pendingTaskCreates: [String: JSONValue] = [:]

    /// Big tool-result lines are only scanned, not decoded, unless they hold a task result.
    static let maxDecodedUserLineBytes = 64 * 1024

    init(startsMidFile: Bool = false) {
        lineBuffer = JSONLLineBuffer(startsMidFile: startsMidFile)
        summary.isComplete = !startsMidFile
    }

    mutating func consume(_ data: Data) {
        for line in lineBuffer.lines(appending: data) {
            parseLine(line)
        }
    }

    // MARK: - Lines

    private static let decoder = JSONDecoder()

    private mutating func parseLine(_ line: Data) {
        let head = line.prefix(160)
        if head.starts(with: Self.aiTitlePrefix) || head.starts(with: Self.customTitlePrefix) || head.starts(with: Self.summaryPrefix) {
            guard let entry = try? Self.decoder.decode(JSONValue.self, from: line) else { return }
            parseTitle(entry)
            return
        }
        if head.firstRange(of: Self.sidechainMarker) != nil { return }

        if line.firstRange(of: Self.assistantMarker) != nil {
            guard let entry = try? Self.decoder.decode(JSONValue.self, from: line),
                  entry["type"]?.stringValue == "assistant" else { return }
            parseAssistant(entry)
        } else if line.firstRange(of: Self.userMarker) != nil {
            let holdsTaskResult = line.firstRange(of: Self.taskResultMarker) != nil
            guard line.count <= Self.maxDecodedUserLineBytes || holdsTaskResult else {
                summary.lastRole = .user // Large tool result: role is enough.
                return
            }
            guard let entry = try? Self.decoder.decode(JSONValue.self, from: line),
                  entry["type"]?.stringValue == "user" else { return }
            parseUser(entry)
        }
    }

    private mutating func parseTitle(_ entry: JSONValue) {
        switch entry["type"]?.stringValue {
        case "ai-title": if let title = entry["aiTitle"]?.stringValue, !title.isEmpty { summary.aiTitle = title }
        case "custom-title": if let title = entry["customTitle"]?.stringValue, !title.isEmpty { summary.customTitle = title }
        case "summary": if summary.aiTitle == nil, let title = entry["summary"]?.stringValue { summary.aiTitle = title }
        default: break
        }
    }

    private mutating func parseAssistant(_ entry: JSONValue) {
        noteTimestamp(entry)
        let message = entry["message"]
        if let model = message?["model"]?.stringValue, !model.hasPrefix("<") {
            summary.model = model
        }
        if let usage = message?["usage"] {
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .compactMap { usage[$0]?.intValue }
                .reduce(0, +)
            if tokens > 0 {
                summary.contextTokens = tokens
                summary.peakContextTokens = max(summary.peakContextTokens, tokens)
            }
        }
        if let effort = entry["effort"]?.stringValue { summary.effort = effort }
        if let branch = entry["gitBranch"]?.stringValue, !branch.isEmpty { summary.gitBranch = branch }
        if let reason = message?["stop_reason"]?.stringValue { summary.lastStopReason = reason }
        summary.lastRole = .assistant

        guard case .array(let blocks)? = message?["content"] else { return }
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    summary.lastAssistantText = text
                }
            case "tool_use":
                guard let name = block["name"]?.stringValue else { continue }
                if name == "TaskCreate", let id = block["id"]?.stringValue {
                    pendingTaskCreates[id] = block["input"] ?? .null
                } else {
                    summary.tasks.apply(toolName: name, input: block["input"], response: nil)
                }
            default:
                break
            }
        }
    }

    private mutating func parseUser(_ entry: JSONValue) {
        noteTimestamp(entry)
        if let mode = entry["permissionMode"]?.stringValue { summary.permissionMode = mode }
        if case .bool(true)? = entry["isMeta"] { return }

        let content = entry["message"]?["content"]
        if case .array(let blocks)? = content {
            for block in blocks where block["type"]?.stringValue == "tool_result" {
                if let toolUseId = block["tool_use_id"]?.stringValue,
                   let input = pendingTaskCreates.removeValue(forKey: toolUseId) {
                    summary.tasks.apply(toolName: "TaskCreate", input: input, response: entry["toolUseResult"])
                }
            }
            if let text = blocks.first?["text"]?.stringValue, text.hasPrefix("[Request interrupted") {
                summary.lastRole = .interrupt
                return
            }
        } else if let text = content?.stringValue, text.hasPrefix("[Request interrupted") {
            summary.lastRole = .interrupt
            return
        }
        summary.lastRole = .user
    }

    private mutating func noteTimestamp(_ entry: JSONValue) {
        guard let raw = entry["timestamp"]?.stringValue, let date = Self.parseDate(raw) else { return }
        if summary.firstTimestamp == nil, summary.isComplete { summary.firstTimestamp = date }
        if summary.lastTimestamp.map({ date > $0 }) ?? true { summary.lastTimestamp = date }
    }

    static func parseDate(_ raw: String) -> Date? {
        (try? Date(raw, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: .iso8601))
    }

    // MARK: - Byte markers (compact JSON, as Claude Code writes it)

    private static let aiTitlePrefix = Data(#"{"type":"ai-title""#.utf8)
    private static let customTitlePrefix = Data(#"{"type":"custom-title""#.utf8)
    private static let summaryPrefix = Data(#"{"type":"summary""#.utf8)
    private static let sidechainMarker = Data(#""isSidechain":true"#.utf8)
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let taskResultMarker = Data(#""toolUseResult":{"task":"#.utf8)
}

/// Picks the context window size. Claude Code does not write it to the transcript.
nonisolated enum ContextWindow {
    static let standard = 200_000
    static let extended = 1_000_000

    /// - Parameter defaultModelSetting: `model` from `~/.claude/settings.json`, e.g. "opus[1m]".
    static func limit(model: String?, peakTokens: Int, defaultModelSetting: String?) -> Int {
        if let model, model.contains("[1m]") { return extended }
        if peakTokens > standard { return extended }
        if let setting = defaultModelSetting?.lowercased(), setting.hasSuffix("[1m]"), let model = model?.lowercased() {
            let family = String(setting.dropLast(4))
            if !family.isEmpty, model.contains(family) || family.contains(model) { return extended }
        }
        return standard
    }
}
