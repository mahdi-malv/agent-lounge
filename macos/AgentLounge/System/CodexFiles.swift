import Foundation

/// Codex local files (PLAN §2 "Codex").
nonisolated enum CodexFiles {
    static var homeDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    /// Thread id → name, from `session_index.jsonl` (`{"id","thread_name","updated_at"}` per line).
    /// Later lines win (renames append).
    static func threadNames() -> [String: String] {
        let url = homeDirectory.appending(path: "session_index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return threadNames(fromIndex: data)
    }

    static func threadNames(fromIndex data: Data) -> [String: String] {
        let decoder = JSONDecoder()
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = try? decoder.decode(JSONValue.self, from: line),
                  let id = entry["id"]?.stringValue,
                  let name = entry["thread_name"]?.stringValue, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}
