import Foundation

/// Incremental parser for an Antigravity transcript (`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`).
///
/// Line shape: `{"step_index":N,"source":"MODEL"|"USER_EXPLICIT","type":"PLANNER_RESPONSE"|"USER_INPUT"|"GENERIC","created_at":"<ISO 8601>",…}`.
/// Used kinds:
/// - `USER_INPUT`: marks `lastRole = .user`,
/// - `PLANNER_RESPONSE`: `model`, `input_tokens`, `cache_read_tokens`, `content`, `tool_calls`.
/// `GENERIC` tool output lines are skipped without decoding.
nonisolated struct AntigravityTranscriptParser: TranscriptParsing {
    private(set) var summary = TranscriptSummary()
    private var lineBuffer: JSONLLineBuffer

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
        let head = line.prefix(200)
        if head.firstRange(of: Self.plannerMarker) != nil {
            guard let entry = try? Self.decoder.decode(JSONValue.self, from: line),
                  entry["type"]?.stringValue == "PLANNER_RESPONSE" else { return }
            parsePlannerResponse(entry)
        } else if head.firstRange(of: Self.userInputMarker) != nil {
            guard let entry = try? Self.decoder.decode(JSONValue.self, from: line),
                  entry["type"]?.stringValue == "USER_INPUT" else { return }
            noteTimestamp(entry)
            summary.lastRole = .user
        }
    }

    private mutating func parsePlannerResponse(_ entry: JSONValue) {
        noteTimestamp(entry)
        if let model = entry["model"]?.stringValue, !model.isEmpty {
            summary.model = model
            if summary.contextWindow == nil {
                summary.contextWindow = ContextWindow.extended
            }
        }
        let tokens = (entry["input_tokens"]?.intValue ?? 0) + (entry["cache_read_tokens"]?.intValue ?? 0)
        if tokens > 0 {
            summary.contextTokens = tokens
            summary.peakContextTokens = max(summary.peakContextTokens, tokens)
        }
        if let content = entry["content"]?.stringValue,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary.lastAssistantText = content
        }
        let hasTools: Bool
        if case .array(let calls)? = entry["tool_calls"] {
            hasTools = !calls.isEmpty
        } else {
            hasTools = false
        }
        summary.lastRole = .assistant
        summary.lastStopReason = hasTools ? "tool_use" : "end_turn"
    }

    private mutating func noteTimestamp(_ entry: JSONValue) {
        guard let raw = entry["created_at"]?.stringValue, let date = TranscriptParser.parseDate(raw) else { return }
        if summary.firstTimestamp == nil, summary.isComplete { summary.firstTimestamp = date }
        if summary.lastTimestamp.map({ date > $0 }) ?? true { summary.lastTimestamp = date }
    }

    // MARK: - Byte markers

    private static let plannerMarker = Data(#""type":"PLANNER_RESPONSE""#.utf8)
    private static let userInputMarker = Data(#""type":"USER_INPUT""#.utf8)
}
