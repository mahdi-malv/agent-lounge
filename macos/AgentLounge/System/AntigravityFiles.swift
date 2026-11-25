import Foundation

/// Antigravity local config files (`~/.gemini/config/`).
nonisolated enum AntigravityFiles {
    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini/config")
    }

    static var hooksURL: URL {
        configDirectory.appending(path: "hooks.json")
    }
}
