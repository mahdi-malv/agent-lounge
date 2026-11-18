import Foundation
import SQLite3
import os

/// One row of the Codex `threads` table (`~/.codex/state_<n>.sqlite`, PLAN §2 "Codex").
nonisolated struct CodexThreadRecord: Equatable, Sendable {
    var id: String
    var rolloutPath: String
    var cwd: String
    /// Unix seconds.
    var createdAt: Double
    var updatedAt: Double
    var model: String?
    var effort: String?
    var gitBranch: String?
    /// Thread name (rename); nil until named.
    var name: String?
}

/// Read-only access to the Codex state database. Codex keeps it open (WAL); we only read.
nonisolated enum CodexStateDB {
    private static let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "CodexStateDB")

    /// Newest `state_<n>.sqlite` in the Codex home (the number is the schema generation).
    static func databaseURL(home: URL = CodexFiles.homeDirectory) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let best = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let number = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (number, name)
        }.max { $0.0 < $1.0 }
        return best.map { home.appending(path: $0.1) }
    }

    /// Main threads (no subagents, not archived) updated at or after `since` (Unix seconds).
    static func threads(updatedSince since: Double, url: URL? = databaseURL()) -> [CodexThreadRecord] {
        guard let url else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            logger.error("Cannot open \(url.path, privacy: .public)")
            return []
        }
        sqlite3_busy_timeout(db, 250)

        let sql = """
            SELECT id, rollout_path, cwd, created_at_ms, updated_at_ms, model, reasoning_effort, git_branch, name
            FROM threads
            WHERE archived = 0 AND updated_at_ms >= ?1 AND agent_path IS NULL
              AND id NOT IN (SELECT child_thread_id FROM thread_spawn_edges)
            ORDER BY updated_at_ms DESC
            LIMIT 200
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            // Schema changed: log once per call, backfill just finds nothing.
            logger.error("Codex threads query failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return []
        }
        sqlite3_bind_int64(statement, 1, Int64(since * 1000))

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            let value = String(cString: pointer)
            return value.isEmpty ? nil : value
        }

        var records: [CodexThreadRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0), let rolloutPath = text(1), let cwd = text(2) else { continue }
            records.append(CodexThreadRecord(
                id: id,
                rolloutPath: rolloutPath,
                cwd: cwd,
                createdAt: Double(sqlite3_column_int64(statement, 3)) / 1000,
                updatedAt: Double(sqlite3_column_int64(statement, 4)) / 1000,
                model: text(5),
                effort: text(6),
                gitBranch: text(7),
                name: text(8)
            ))
        }
        return records
    }
}
