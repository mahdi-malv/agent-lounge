import Foundation

/// Incremental parser for a Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread>.jsonl`).
///
/// Line shape (Codex 0.169): `{"timestamp":…,"ordinal":N,"type":<kind>,"payload":{…}}`. Used kinds:
/// - `session_meta`: `cwd`, `git.branch` (first line; forked subagents add the parent's after it),
/// - `turn_context`: `model`, `effort`,
/// - `event_msg` `token_count`: `info.last_token_usage.input_tokens`, `info.model_context_window`,
/// - `event_msg` `task_started` / `task_complete` (`last_agent_message`) / `turn_aborted`,
/// - `response_item` `function_call` `update_plan` (older versions; 0.169 has no plan tool).
/// Other lines (reasoning, tool output, messages) are skipped without decoding.
nonisolated struct CodexRolloutParser: TranscriptParsing {
    private(set) var summary = TranscriptSummary()
    private var lineBuffer: JSONLLineBuffer
    private var sawSessionMeta = false

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
        noteTimestamp(head)
        let wanted = Self.markers.contains { head.firstRange(of: $0) != nil }
            || (head.firstRange(of: Self.functionCallMarker) != nil && line.firstRange(of: Self.planToolMarker) != nil)
        guard wanted,
              let entry = try? Self.decoder.decode(JSONValue.self, from: line),
              let payload = entry["payload"] else { return }

        switch (entry["type"]?.stringValue, payload["type"]?.stringValue) {
        case ("session_meta", _):
            guard !sawSessionMeta else { return }
            sawSessionMeta = true
            if let branch = payload["git"]?["branch"]?.stringValue, !branch.isEmpty { summary.gitBranch = branch }

        case ("turn_context", _):
            if let model = payload["model"]?.stringValue, !model.isEmpty { summary.model = model }
            if let effort = payload["effort"]?.stringValue, !effort.isEmpty { summary.effort = effort }

        case ("event_msg", "token_count"):
            let info = payload["info"]
            if let tokens = info?["last_token_usage"]?["input_tokens"]?.intValue, tokens > 0 {
                summary.contextTokens = tokens
                summary.peakContextTokens = max(summary.peakContextTokens, tokens)
            }
            if let window = info?["model_context_window"]?.intValue, window > 0 { summary.contextWindow = window }

        case ("event_msg", "task_started"):
            if let window = payload["model_context_window"]?.intValue, window > 0 { summary.contextWindow = window }
            summary.lastRole = .user

        case ("event_msg", "task_complete"):
            if let text = payload["last_agent_message"]?.stringValue,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summary.lastAssistantText = text
            }
            summary.lastRole = .assistant
            summary.lastStopReason = "end_turn"

        case ("event_msg", "turn_aborted"):
            summary.lastRole = .interrupt

        case ("response_item", "function_call"):
            guard let name = payload["name"]?.stringValue,
                  let arguments = payload["arguments"]?.stringValue,
                  let input = try? Self.decoder.decode(JSONValue.self, from: Data(arguments.utf8)) else { return }
            summary.tasks.apply(toolName: name, input: input, response: nil)

        default:
            break
        }
    }

    /// Lines start with `{"timestamp":"<ISO 8601>"`; read it without decoding the line.
    private mutating func noteTimestamp(_ head: Data) {
        guard head.starts(with: Self.timestampPrefix) else { return }
        let rest = head.dropFirst(Self.timestampPrefix.count)
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")),
              let date = TranscriptParser.parseDate(String(decoding: rest[..<end], as: UTF8.self)) else { return }
        if summary.firstTimestamp == nil, summary.isComplete { summary.firstTimestamp = date }
        if summary.lastTimestamp.map({ date > $0 }) ?? true { summary.lastTimestamp = date }
    }

    // MARK: - Byte markers (compact JSON, as Codex writes it)

    private static let timestampPrefix = Data(#"{"timestamp":""#.utf8)
    private static let markers: [Data] = [
        #""type":"session_meta""#,
        #""type":"turn_context""#,
        #""payload":{"type":"token_count""#,
        #""payload":{"type":"task_started""#,
        #""payload":{"type":"task_complete""#,
        #""payload":{"type":"turn_aborted""#,
    ].map { Data($0.utf8) }
    /// Key order inside `function_call` varies, so the tool name is searched in the whole line.
    private static let functionCallMarker = Data(#""payload":{"type":"function_call""#.utf8)
    private static let planToolMarker = Data(#""name":"update_plan""#.utf8)
}
