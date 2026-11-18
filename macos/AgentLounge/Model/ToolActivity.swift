import Foundation

/// Tool call → card activity line (PLAN §4), e.g. "Editing Foo.swift", "Running npm test".
nonisolated enum ToolActivity {
    static func describe(_ tool: ToolCall) -> String {
        let input = tool.input
        func string(_ key: String) -> String? { input?[key]?.stringValue?.firstLine }
        func file(_ key: String) -> String? { string(key).map { URL(fileURLWithPath: $0).lastPathComponent } }

        switch tool.name {
        case "Read":
            return file("file_path").map { "Reading \($0)" } ?? "Reading a file"
        case "Edit", "MultiEdit":
            return file("file_path").map { "Editing \($0)" } ?? "Editing a file"
        case "Write":
            return file("file_path").map { "Writing \($0)" } ?? "Writing a file"
        case "NotebookEdit":
            return file("notebook_path").map { "Editing \($0)" } ?? "Editing a notebook"
        case "Bash", "BashOutput":
            // Claude writes a short description for each command; it reads better than the command.
            if let description = string("description") { return clip(description, 70) }
            return string("command").map { "Running \(clip($0))" } ?? "Running a command"
        case "Grep":
            return string("pattern").map { "Searching for “\(clip($0, 40))”" } ?? "Searching code"
        case "Glob":
            return string("pattern").map { "Finding files \(clip($0, 40))" } ?? "Finding files"
        case "WebFetch":
            return string("url").map { "Fetching \(host(of: $0))" } ?? "Fetching a page"
        case "WebSearch":
            return string("query").map { "Searching the web for “\(clip($0, 40))”" } ?? "Searching the web"
        case "Task", "Agent":
            let what = string("description") ?? string("subagent_type")
            return what.map { "Subagent: \(clip($0, 50))" } ?? "Running a subagent"
        case "TaskCreate":
            return string("subject").map { "Planning: \(clip($0, 50))" } ?? "Planning tasks"
        case "TaskUpdate", "TodoWrite":
            return "Updating the task list"
        case "TaskList", "TaskGet":
            return "Checking the task list"
        case "AskUserQuestion":
            return "Asking you a question"
        case "ExitPlanMode":
            return "Presenting a plan"
        case "Skill":
            return string("skill").map { "Using skill \($0)" } ?? "Using a skill"
        case "ToolSearch":
            return "Loading tools"
        // Codex tool names (hooks report shell and unified exec as "Bash").
        case "apply_patch":
            return input?["command"]?.stringValue.flatMap(patchSummary) ?? "Editing files"
        case "update_plan":
            return "Updating the plan"
        case "spawn_agent":
            return "Starting a subagent"
        case "wait_agent":
            return "Waiting for subagents"
        case "request_user_input":
            return "Asking you a question"
        default:
            if tool.name.hasPrefix("mcp__") {
                let parts = tool.name.split(separator: "__", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    return "Using \(parts[1]) · \(parts[2...].joined(separator: "__"))"
                }
            }
            return "Using \(tool.name)"
        }
    }

    /// Text for a `needsInput` card when the tool itself waits for the user.
    static func waitingText(_ tool: ToolCall) -> String? {
        switch tool.name {
        case "AskUserQuestion", "request_user_input":
            if case .array(let questions)? = tool.input?["questions"],
               let question = questions.first?["question"]?.stringValue?.firstLine {
                return clip(question, 90)
            }
            return tool.name == "AskUserQuestion" ? "Claude has a question" : "Codex has a question"
        case "ExitPlanMode":
            return "Plan ready for review"
        default:
            return nil
        }
    }

    /// Codex `apply_patch` text → "Editing Foo.swift" / "Editing Foo.swift and 2 more".
    static func patchSummary(_ patch: String) -> String? {
        let verbs = [("*** Update File: ", "Editing"), ("*** Add File: ", "Writing"), ("*** Delete File: ", "Deleting")]
        var files: [(verb: String, name: String)] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            for (prefix, verb) in verbs where line.hasPrefix(prefix) {
                let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                files.append((verb, URL(fileURLWithPath: path).lastPathComponent))
            }
        }
        guard let first = files.first else { return nil }
        let more = files.count > 1 ? " and \(files.count - 1) more" : ""
        return "\(first.verb) \(first.name)\(more)"
    }

    private static func clip(_ text: String, _ limit: Int = 60) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func host(of url: String) -> String {
        URL(string: url)?.host() ?? clip(url, 40)
    }
}
