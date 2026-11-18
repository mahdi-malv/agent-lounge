import Foundation
import SQLite3
import Testing
@testable import AgentLounge

@Suite("Codex backfill")
struct CodexBackfillTests {
    private static let codexPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    private func process(_ pid: Int32, start: Double, cwd: String = "/work/app", _ arguments: String...) -> CodexProcess {
        CodexProcess(pid: pid, startTime: start, workingDirectory: cwd, arguments: [Self.codexPath] + arguments)
    }

    private func thread(_ id: String, cwd: String = "/work/app", created: Double, updated: Double? = nil) -> CodexThreadRecord {
        CodexThreadRecord(id: id, rolloutPath: "/r/\(id).jsonl", cwd: cwd, createdAt: created, updatedAt: updated ?? created)
    }

    private func pairs(_ matches: [CodexBackfill.Match]) -> [Int32: String] {
        Dictionary(uniqueKeysWithValues: matches.map { ($0.process.pid, $0.thread.id) })
    }

    @Test func threadGoesToNewestProcessStartedBeforeIt() {
        let matches = CodexBackfill.match(
            processes: [process(1, start: 100), process(2, start: 200)],
            threads: [thread("a", created: 108, updated: 500), thread("b", created: 205, updated: 400)]
        )
        #expect(pairs(matches) == [1: "a", 2: "b"])
    }

    @Test func oneCardPerProcessTakesTheNewestThread() {
        // `/new` in the TUI: the older thread stays in the database.
        let matches = CodexBackfill.match(
            processes: [process(1, start: 100)],
            threads: [thread("old", created: 110, updated: 150), thread("new", created: 160, updated: 300)]
        )
        #expect(pairs(matches) == [1: "new"])
    }

    @Test func otherFolderAndOlderThreadsDoNotMatch() {
        let matches = CodexBackfill.match(
            processes: [process(1, start: 100)],
            threads: [thread("elsewhere", cwd: "/work/other", created: 120), thread("before", created: 50, updated: 60)]
        )
        #expect(matches.isEmpty)
    }

    @Test func resumeWithIDNamesTheThread() {
        let id = "01a1ec4e-9e7a-7201-bc93-2b107228a4a7"
        let matches = CodexBackfill.match(
            processes: [process(1, start: 100, "-m", "gpt-6-sol", "resume", id)],
            threads: [thread(id, cwd: "/elsewhere", created: 10, updated: 20)]
        )
        #expect(pairs(matches) == [1: id])
    }

    @Test func resumeLastTakesTheThreadActiveSinceStart() {
        let matches = CodexBackfill.match(
            processes: [process(1, start: 100, "resume", "--last")],
            threads: [thread("idle", created: 10, updated: 40), thread("resumed", created: 20, updated: 130)]
        )
        #expect(pairs(matches) == [1: "resumed"])
    }

    @Test func serversAreNotSessions() {
        let matches = CodexBackfill.match(
            processes: [process(1, start: 100, "app-server"), process(2, start: 90, "-c", "x=1", "Fix the bug")],
            threads: [thread("t", created: 120)]
        )
        #expect(pairs(matches) == [2: "t"])
    }

    @Test func cdOptionSetsTheFolder() {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let real = String(cString: realpath(tmp, nil))
        let codex = process(1, start: 100, cwd: "/", "-C", tmp, "exec", "hi")
        #expect(CodexBackfill.directory(of: codex) == real)
        #expect(CodexBackfill.directory(of: process(2, start: 0, "--cd=/")) == "/")
        #expect(CodexBackfill.directory(of: process(3, start: 0, "-c", "cd=/x")) == "/work/app")
    }

    @Test func subcommandSkipsOptionValues() {
        #expect(CodexBackfill.subcommand([Self.codexPath, "-c", "hooks.Stop=[]", "--enable", "x", "exec", "hi"]) == "exec")
        #expect(CodexBackfill.subcommand([Self.codexPath, "--dangerously-bypass-hook-trust"]) == nil)
        #expect(CodexBackfill.resumedThreadID([Self.codexPath, "exec", "resume", "not-a-uuid"]) == nil)
    }

    @Test func stateDatabaseReadsMainThreadsOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "codex-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["state_4.sqlite", "state_5.sqlite", "logs_2.sqlite"] {
            FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: nil)
        }
        let url = try #require(CodexStateDB.databaseURL(home: folder))
        #expect(url.lastPathComponent == "state_5.sqlite")

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL, cwd TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, git_branch TEXT,
              model TEXT, reasoning_effort TEXT, agent_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, name TEXT);
            CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);
            INSERT INTO threads VALUES ('main', '/r/main.jsonl', 1, 2, '/w', 0, 'main', 'gpt-6-sol', 'high', NULL, 1000, 2500, 'Fix tests');
            INSERT INTO threads VALUES ('old', '/r/old.jsonl', 0, 0, '/w', 0, NULL, NULL, NULL, NULL, 0, 500, NULL);
            INSERT INTO threads VALUES ('gone', '/r/gone.jsonl', 1, 2, '/w', 1, NULL, NULL, NULL, NULL, 1000, 2000, NULL);
            INSERT INTO threads VALUES ('child', '/r/child.jsonl', 1, 2, '/w', 0, NULL, NULL, NULL, NULL, 1000, 2000, NULL);
            INSERT INTO threads VALUES ('agent', '/r/agent.jsonl', 1, 2, '/w', 0, NULL, NULL, NULL, 'a/b', 1000, 2000, NULL);
            INSERT INTO thread_spawn_edges VALUES ('main', 'child', 'open');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let threads = CodexStateDB.threads(updatedSince: 1, url: url)
        #expect(threads == [CodexThreadRecord(
            id: "main", rolloutPath: "/r/main.jsonl", cwd: "/w", createdAt: 1, updatedAt: 2.5,
            model: "gpt-6-sol", effort: "high", gitBranch: "main", name: "Fix tests"
        )])
    }
}
