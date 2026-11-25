import Foundation

/// Task list built from task-tool calls (TaskCreate / TaskUpdate, TodoWrite fallback, Codex `update_plan`).
///
/// Two books exist per session: one replayed from the transcript (base, for sessions that
/// started before the app) and one from live hooks (overlay; the transcript lags behind hooks).
/// `merged(base:overlay:)` combines them per task id, overlay first.
nonisolated struct TaskBook: Codable, Hashable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        var subject: String?
        var activeForm: String?
        var status: AgentTask.Status?
        var isDeleted = false
    }

    private(set) var order: [String] = []
    private(set) var entries: [String: Entry] = [:]
    /// Last full TodoWrite list. When set, it replaces everything else.
    private(set) var todos: [AgentTask]?

    var isEmpty: Bool { entries.isEmpty && todos == nil }

    mutating func create(id: String, subject: String?, activeForm: String?) {
        edit(id) { entry in
            if let subject, !subject.isEmpty { entry.subject = subject }
            if let activeForm, !activeForm.isEmpty { entry.activeForm = activeForm }
            if entry.status == nil { entry.status = .pending }
        }
    }

    /// `status` is the raw tool value: pending, in_progress, completed, deleted.
    mutating func update(id: String, status: String?, subject: String? = nil, activeForm: String? = nil) {
        edit(id) { entry in
            if let subject, !subject.isEmpty { entry.subject = subject }
            if let activeForm, !activeForm.isEmpty { entry.activeForm = activeForm }
            if status == "deleted" {
                entry.isDeleted = true
            } else if let status = status.flatMap(Self.status(from:)) {
                entry.status = status
            }
        }
    }

    mutating func replaceTodos(_ items: [AgentTask]) {
        todos = items
    }

    /// Applies one task-tool call. `response` is the tool result (`tool_response` in hooks,
    /// `toolUseResult` in transcripts). Returns false for other tools.
    @discardableResult
    mutating func apply(toolName: String, input: JSONValue?, response: JSONValue?) -> Bool {
        switch toolName {
        case "TaskCreate":
            guard let id = response?["task"]?["id"]?.stringValue else { return true }
            create(
                id: id,
                subject: input?["subject"]?.stringValue ?? response?["task"]?["subject"]?.stringValue,
                activeForm: input?["activeForm"]?.stringValue
            )
            return true
        case "TaskUpdate":
            guard let id = input?["taskId"]?.stringValue else { return true }
            update(
                id: id,
                status: input?["status"]?.stringValue,
                subject: input?["subject"]?.stringValue,
                activeForm: input?["activeForm"]?.stringValue
            )
            return true
        case "TodoWrite":
            guard case .array(let items)? = input?["todos"] else { return true }
            let tasks = items.enumerated().compactMap { index, item -> AgentTask? in
                guard let content = item["content"]?.stringValue else { return nil }
                return AgentTask(
                    id: String(index + 1),
                    subject: content,
                    activeForm: item["activeForm"]?.stringValue,
                    status: item["status"]?.stringValue.flatMap(Self.status(from:)) ?? .pending
                )
            }
            replaceTodos(tasks)
            return true
        case "update_plan":
            // Codex: full plan each call, `[{step, status}]`.
            guard case .array(let items)? = input?["plan"] else { return true }
            let tasks = items.enumerated().compactMap { index, item -> AgentTask? in
                guard let step = item["step"]?.stringValue else { return nil }
                return AgentTask(
                    id: String(index + 1),
                    subject: step,
                    activeForm: nil,
                    status: item["status"]?.stringValue.flatMap(Self.status(from:)) ?? .pending
                )
            }
            replaceTodos(tasks)
            return true
        case "update_steps":
            // Antigravity: full checklist each call, `[{title, status}]`.
            guard case .array(let items)? = input?["steps"] else { return true }
            let tasks = items.enumerated().compactMap { index, item -> AgentTask? in
                guard let title = item["title"]?.stringValue else { return nil }
                return AgentTask(
                    id: String(index + 1),
                    subject: title,
                    activeForm: nil,
                    status: item["status"]?.stringValue.flatMap(Self.status(from:)) ?? .pending
                )
            }
            replaceTodos(tasks)
            return true
        default:
            return false
        }
    }

    /// Display list. Overlay values win; tasks without a known subject stay hidden.
    static func merged(base: TaskBook, overlay: TaskBook) -> [AgentTask] {
        if let todos = overlay.todos ?? base.todos { return todos }

        var ids = base.order
        for id in overlay.order where base.entries[id] == nil {
            ids.append(id)
        }
        let tasks = ids.compactMap { id -> AgentTask? in
            let low = base.entries[id]
            let high = overlay.entries[id]
            if low?.isDeleted == true || high?.isDeleted == true { return nil }
            guard let subject = high?.subject ?? low?.subject else { return nil }
            return AgentTask(
                id: id,
                subject: subject,
                activeForm: high?.activeForm ?? low?.activeForm,
                status: high?.status ?? low?.status ?? .pending
            )
        }
        return tasks.enumerated()
            .sorted { lhs, rhs in
                switch (Int(lhs.element.id), Int(rhs.element.id)) {
                case let (left?, right?): left < right
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    private mutating func edit(_ id: String, _ change: (inout Entry) -> Void) {
        if entries[id] == nil {
            order.append(id)
        }
        var entry = entries[id] ?? Entry()
        change(&entry)
        entries[id] = entry
    }

    private static func status(from raw: String) -> AgentTask.Status? {
        switch raw {
        case "pending": .pending
        case "in_progress": .inProgress
        case "completed", "done": .completed
        default: nil
        }
    }
}
