import Foundation
import os

/// Installs and removes Agent Lounge hooks in the agents' config files (PLAN §7, D12).
///
/// Safety rules:
/// - A file that is not valid JSON is never written.
/// - Before a change, the file is copied to `<name>.agent-lounge-backup-<yyyyMMdd-HHmmss>`.
/// - Symlinks are followed (dotfile managers); the file mode is kept.
/// - Only our handlers (and the env var we added) are touched. Codex `notify` is never touched.
final class HookInstaller {
    struct Target {
        var config: HookConfig
        var fileURL: URL
    }

    struct Change {
        /// Nil when the file did not change (or did not exist before).
        var backupURL: URL?
        var changed: Bool
    }

    enum InstallError: LocalizedError {
        case hookMissing(String)
        case invalidFile(URL, String)

        var errorDescription: String? {
            switch self {
            case .hookMissing(let path): "lounge-hook is missing at \(path)."
            case .invalidFile(let url, let reason): "\(url.path) is not valid JSON (\(reason)). Nothing was changed."
            }
        }
    }

    let hookPath: String
    let claude: Target
    let codex: Target
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Installer")
    private static let addedTodoEnvKey = "installer.claude.addedTodoToolsEnv"

    init(
        hookPath: String = HookInstaller.bundledHookPath,
        claudeSettings: URL = ClaudeFiles.configDirectory.appending(path: "settings.json"),
        codexHooks: URL = CodexFiles.homeDirectory.appending(path: "hooks.json"),
        defaults: UserDefaults = .standard
    ) {
        self.hookPath = hookPath
        claude = Target(config: .claude, fileURL: claudeSettings)
        codex = Target(config: .codex, fileURL: codexHooks)
        self.defaults = defaults
    }

    static var bundledHookPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/bin/lounge-hook").path
    }

    func target(_ agent: AgentKind) -> Target {
        agent == .codex ? codex : claude
    }

    func command(for agent: AgentKind) -> String {
        HookConfig.command(hookPath: hookPath, agent: agent)
    }

    // MARK: - Status

    func status(_ agent: AgentKind) -> Result<HookConfig.Status, Error> {
        let target = target(agent)
        do {
            let config = try read(target.fileURL)
            return .success(target.config.status(of: config, command: command(for: agent)))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Install / uninstall

    @discardableResult
    func install(_ agent: AgentKind) throws -> Change {
        guard FileManager.default.isExecutableFile(atPath: hookPath) else { throw InstallError.hookMissing(hookPath) }
        let target = target(agent)
        let before = try read(target.fileURL)
        var after = target.config.installed(before, command: command(for: agent))
        if agent == .claude, let withEnv = HookConfig.withTodoTools(after) {
            after = withEnv
            defaults.set(true, forKey: Self.addedTodoEnvKey)
        }
        return try write(after, replacing: before, at: target.fileURL)
    }

    @discardableResult
    func uninstall(_ agent: AgentKind) throws -> Change {
        let target = target(agent)
        let before = try read(target.fileURL)
        var after = target.config.uninstalled(before)
        if agent == .claude, defaults.bool(forKey: Self.addedTodoEnvKey) {
            after = HookConfig.withoutTodoTools(after)
            defaults.removeObject(forKey: Self.addedTodoEnvKey)
        }
        // Codex: a hooks file with nothing left is removed (we created it).
        if agent == .codex, after == .emptyObject, FileManager.default.fileExists(atPath: target.fileURL.path) {
            let backup = try backUp(target.fileURL)
            try FileManager.default.removeItem(at: target.fileURL.resolvingSymlinksInPath())
            logger.info("Removed \(target.fileURL.path, privacy: .public) (backup \(backup.lastPathComponent, privacy: .public))")
            return Change(backupURL: backup, changed: true)
        }
        return try write(after, replacing: before, at: target.fileURL)
    }

    // MARK: - Files

    /// Missing file = empty object.
    private func read(_ url: URL) throws -> OrderedJSON {
        let url = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return .emptyObject }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .emptyObject }
        do {
            let value = try OrderedJSON.parse(data)
            guard case .object = value else { throw InstallError.invalidFile(url, "top level is not an object") }
            return value
        } catch let error as OrderedJSON.ParseError {
            throw InstallError.invalidFile(url, error.description)
        }
    }

    private func write(_ value: OrderedJSON, replacing old: OrderedJSON, at url: URL) throws -> Change {
        guard value != old else { return Change(backupURL: nil, changed: false) }
        let url = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        let mode = exists ? (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber : nil
        let backup = exists ? try backUp(url) : nil
        if !exists {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data((value.prettyText() + "\n").utf8).write(to: url, options: .atomic)
        if let mode {
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        logger.info("Wrote \(url.path, privacy: .public) (backup \(backup?.lastPathComponent ?? "none", privacy: .public))")
        return Change(backupURL: backup, changed: true)
    }

    private func backUp(_ url: URL) throws -> URL {
        let url = url.resolvingSymlinksInPath()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backup = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).agent-lounge-backup-\(formatter.string(from: .now))")
        var counter = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.deletingLastPathComponent()
                .appending(path: "\(url.lastPathComponent).agent-lounge-backup-\(formatter.string(from: .now))-\(counter)")
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }
}
