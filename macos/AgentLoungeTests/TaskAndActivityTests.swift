import Foundation
import Testing
@testable import AgentLounge

struct TaskBookTests {
    private func createResponse(_ id: String) -> JSONValue {
        .object(["task": .object(["id": .string(id), "subject": .string("ignored")])])
    }

    @Test func createAndUpdate() {
        var book = TaskBook()
        book.apply(toolName: "TaskCreate", input: .object(["subject": .string("Write intro"), "activeForm": .string("Writing intro")]), response: createResponse("1"))
        book.apply(toolName: "TaskCreate", input: .object(["subject": .string("Write outro")]), response: createResponse("2"))
        book.apply(toolName: "TaskUpdate", input: .object(["taskId": .string("1"), "status": .string("in_progress")]), response: nil)

        let tasks = TaskBook.merged(base: TaskBook(), overlay: book)
        #expect(tasks.map(\.subject) == ["Write intro", "Write outro"])
        #expect(tasks.map(\.status) == [.inProgress, .pending])
        #expect(tasks[0].activeForm == "Writing intro")
    }

    @Test func deletedTasksDisappear() {
        var book = TaskBook()
        book.create(id: "1", subject: "A", activeForm: nil)
        book.create(id: "2", subject: "B", activeForm: nil)
        book.update(id: "1", status: "deleted")
        #expect(TaskBook.merged(base: TaskBook(), overlay: book).map(\.id) == ["2"])
    }

    @Test func overlayWinsAndFillsFromBase() {
        // Transcript knows tasks 1–3; hooks (after app start) only saw updates and a new task.
        var base = TaskBook()
        base.create(id: "1", subject: "One", activeForm: "Doing one")
        base.create(id: "2", subject: "Two", activeForm: nil)
        base.create(id: "3", subject: "Three", activeForm: nil)
        base.update(id: "1", status: "completed")

        var overlay = TaskBook()
        overlay.update(id: "2", status: "in_progress")
        overlay.create(id: "4", subject: "Four", activeForm: nil)
        overlay.update(id: "9", status: "completed") // Unknown subject: hidden.

        let tasks = TaskBook.merged(base: base, overlay: overlay)
        #expect(tasks.map(\.id) == ["1", "2", "3", "4"])
        #expect(tasks.map(\.status) == [.completed, .inProgress, .pending, .pending])
    }

    @Test func sortsNumericIds() {
        var book = TaskBook()
        for id in ["10", "2", "1"] { book.create(id: id, subject: "T\(id)", activeForm: nil) }
        #expect(TaskBook.merged(base: TaskBook(), overlay: book).map(\.id) == ["1", "2", "10"])
    }

    @Test func todoWriteReplacesList() {
        var book = TaskBook()
        book.create(id: "1", subject: "Old", activeForm: nil)
        book.apply(toolName: "TodoWrite", input: .object(["todos": .array([
            .object(["content": .string("A"), "status": .string("completed"), "activeForm": .string("Doing A")]),
            .object(["content": .string("B"), "status": .string("in_progress"), "activeForm": .string("Doing B")]),
        ])]), response: nil)
        let tasks = TaskBook.merged(base: TaskBook(), overlay: book)
        #expect(tasks.map(\.subject) == ["A", "B"])
        #expect(TaskProgress(done: 1, total: 2, active: tasks[1]).label == "Doing B")
    }

    @Test func otherToolsAreIgnored() {
        var book = TaskBook()
        #expect(book.apply(toolName: "Bash", input: nil, response: nil) == false)
        #expect(book.isEmpty)
    }
}

struct ToolActivityTests {
    private func describe(_ name: String, _ input: [String: String] = [:]) -> String {
        ToolActivity.describe(ToolCall(name: name, input: .object(input.mapValues { .string($0) }), useId: nil))
    }

    @Test func verbs() {
        #expect(describe("Read", ["file_path": "/a/b/Foo.swift"]) == "Reading Foo.swift")
        #expect(describe("Edit", ["file_path": "/a/Bar.kt"]) == "Editing Bar.kt")
        #expect(describe("Write", ["file_path": "/a/README.md"]) == "Writing README.md")
        #expect(describe("Bash", ["command": "./gradlew test\necho done"]) == "Running ./gradlew test")
        #expect(describe("Grep", ["pattern": "TODO"]) == "Searching for “TODO”")
        #expect(describe("WebFetch", ["url": "https://code.claude.com/docs/en/hooks"]) == "Fetching code.claude.com")
        #expect(describe("Agent", ["description": "Explore the repo"]) == "Subagent: Explore the repo")
        #expect(describe("mcp__github__create_issue") == "Using github · create_issue")
        #expect(describe("SomethingNew") == "Using SomethingNew")
        #expect(describe("Bash") == "Running a command")
        #expect(describe("Bash", ["command": "cd x && make test", "description": "Run unit tests"]) == "Run unit tests")
    }

    @Test func longCommandsAreClipped() {
        let text = describe("Bash", ["command": String(repeating: "x", count: 200)])
        #expect(text.count <= "Running ".count + 60)
        #expect(text.hasSuffix("…"))
    }

    @Test func waitingTools() {
        let question = ToolCall(
            name: "AskUserQuestion",
            input: .object(["questions": .array([.object(["question": .string("Which port?")])])]),
            useId: nil
        )
        #expect(ToolActivity.waitingText(question) == "Which port?")
        #expect(ToolActivity.waitingText(ToolCall(name: "ExitPlanMode", input: nil, useId: nil)) == "Plan ready for review")
        #expect(ToolActivity.waitingText(ToolCall(name: "Bash", input: nil, useId: nil)) == nil)
    }
}

struct ReducerM3Tests {
    @Test func askUserQuestionNeedsInput() {
        var session = SessionReducer.newSession(for: TestEvents.event("UserPromptSubmit"))
        let ask: [String: Any] = ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Ship it?"]]]]
        SessionReducer.apply(TestEvents.event("PreToolUse", extra: ask), to: &session)
        #expect(session.state == .needsInput)
        #expect(session.attention == "Ship it?")
        SessionReducer.apply(TestEvents.event("PostToolUse", extra: ask), to: &session)
        #expect(session.state == .running)
    }

    @Test func liveTasksFromPostToolUse() {
        var session = SessionReducer.newSession(for: TestEvents.event("UserPromptSubmit"))
        SessionReducer.apply(TestEvents.event("PostToolUse", extra: [
            "tool_name": "TaskCreate",
            "tool_input": ["subject": "Write intro", "activeForm": "Writing intro"],
            "tool_response": ["task": ["id": "1", "subject": "Write intro"]],
        ]), to: &session)
        SessionReducer.apply(TestEvents.event("PostToolUse", extra: [
            "tool_name": "TaskUpdate",
            "tool_input": ["taskId": "1", "status": "in_progress"],
            "tool_response": ["success": true],
        ]), to: &session)
        #expect(session.progress?.total == 1)
        #expect(session.progress?.label == "Writing intro")

        SessionReducer.apply(TestEvents.event("TaskCompleted", extra: ["task_id": "1"]), to: &session)
        #expect(session.progress?.done == 1)
    }

    @Test func activityUsesVerbs() {
        var session = SessionReducer.newSession(for: TestEvents.event("UserPromptSubmit"))
        SessionReducer.apply(TestEvents.event("PreToolUse", extra: TestEvents.bash("npm test")), to: &session)
        #expect(session.activity == "Running npm test")
    }
}

struct ContextWindowTests {
    @Test func limits() {
        #expect(ContextWindow.limit(model: "claude-opus-5-5[1m]", peakTokens: 0, defaultModelSetting: nil) == 1_000_000)
        #expect(ContextWindow.limit(model: "claude-sonnet-5-5", peakTokens: 250_000, defaultModelSetting: nil) == 1_000_000)
        #expect(ContextWindow.limit(model: "claude-opus-5-5", peakTokens: 10_000, defaultModelSetting: "opus[1m]") == 1_000_000)
        #expect(ContextWindow.limit(model: "claude-haiku-5-5", peakTokens: 10_000, defaultModelSetting: "opus[1m]") == 200_000)
        #expect(ContextWindow.limit(model: nil, peakTokens: 0, defaultModelSetting: nil) == 200_000)
    }
}
