import Foundation

/// One `~/.claude/sessions/<pid>.json` file. Claude Code (CLI and Claude.app) writes one
/// per running process and updates `sessionId` on `/clear`.
nonisolated struct ClaudeProcessRecord: Decodable, Sendable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    /// Unix milliseconds.
    var startedAt: Double?
    /// Process start in UTC, e.g. "Tue Nov 17 10:25:43 2026".
    var procStart: String?
    /// "interactive", …
    var kind: String?
    /// "cli" or "claude-desktop".
    var entrypoint: String?
    /// Claude.app session id, "local_…".
    var hostSessionId: String?
    var name: String?
    /// "busy" or "idle".
    var status: String?
    /// Unix milliseconds.
    var statusUpdatedAt: Double?
}

nonisolated enum ClaudeFiles {
    static var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    /// Records of running interactive sessions. Stale files (dead or reused PIDs) are skipped.
    static func liveSessionRecords() -> [ClaudeProcessRecord] {
        let directory = configDirectory.appending(path: "sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> ClaudeProcessRecord? in
                guard let data = FileManager.default.contents(atPath: directory.appending(path: name).path),
                      let record = try? decoder.decode(ClaudeProcessRecord.self, from: data) else { return nil }
                guard record.kind == nil || record.kind == "interactive" else { return nil }
                guard let info = ProcessInspector.info(record.pid), !info.isZombie else { return nil }
                if let procStart = record.procStart, let started = parseProcStart(procStart),
                   abs(started.timeIntervalSince1970 - info.startTime) > 2 {
                    return nil // PID was reused.
                }
                return record
            }
    }

    /// The record of one process, if its file exists.
    static func record(pid: Int32) -> ClaudeProcessRecord? {
        let url = configDirectory.appending(path: "sessions").appending(path: "\(pid).json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(ClaudeProcessRecord.self, from: data)
    }

    static func parseProcStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC") // Claude Code writes UTC (checked 2026-11-18).
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let normalized = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: normalized)
    }

    /// `~/.claude/projects/<cwd with non-alphanumerics as "-">/<sessionId>.jsonl`, if it exists.
    static func transcriptPath(cwd: String, sessionId: String) -> String? {
        let projects = configDirectory.appending(path: "projects")
        let fileName = "\(sessionId).jsonl"
        let mangled = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = projects.appending(path: mangled).appending(path: fileName).path
        if FileManager.default.fileExists(atPath: direct) { return direct }

        // Fallback: look in every project folder.
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for folder in folders {
            let candidate = projects.appending(path: folder).appending(path: fileName).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `model` from `~/.claude/settings.json`, e.g. "opus[1m]".
    static func defaultModelSetting() -> String? {
        let url = configDirectory.appending(path: "settings.json")
        guard let data = FileManager.default.contents(atPath: url.path),
              let settings = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return settings["model"]?.stringValue
    }
}

nonisolated enum GitInfo {
    /// Current branch of the repository that contains `directory`. Short hash when detached.
    static func branch(at directory: String) -> String? {
        var url = URL(fileURLWithPath: directory)
        let fileManager = FileManager.default
        for _ in 0..<32 {
            let dotGit = url.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = dotGit
                } else {
                    // Worktree or submodule: ".git" is a file "gitdir: <path>".
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDirectory = URL(fileURLWithPath: path, relativeTo: url)
                }
                guard let head = try? String(contentsOf: gitDirectory.appending(path: "HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: refs/heads/") {
                    return String(head.dropFirst("ref: refs/heads/".count))
                }
                return head.isEmpty ? nil : String(head.prefix(7))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}
