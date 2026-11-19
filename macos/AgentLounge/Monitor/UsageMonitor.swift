import Foundation
import Observation
import os

/// Plan usage for the top bar (panel and phone).
/// - Codex: newest `rate_limits` in the recent rollouts (`~/.codex/sessions/YYYY/MM/DD`). No network.
/// - Claude: `GET api.anthropic.com/api/oauth/usage` with the Claude Code sign-in (Keychain item
///   "Claude Code-credentials" read through `/usr/bin/security`, or `~/.claude/.credentials.json`).
///   Off until the user turns it on. The token stays in memory until it expires or is refused.
@Observable
final class UsageMonitor {
    static let codexInterval: Duration = .seconds(30)
    static let claudeInterval: Duration = .seconds(180)
    /// Least time between two sign-in reads while the stored token is expired or refused.
    static let staleCredentialsRetry: TimeInterval = 30 * 60

    private(set) var claude: AgentUsage?
    private(set) var codex: AgentUsage?

    /// Usage to show, Claude first.
    var usages: [AgentUsage] { [claude, codex].compactMap(\.self) }

    @ObservationIgnored var claudeEnabled: () -> Bool = { false }
    @ObservationIgnored private var codexLoop: Task<Void, Never>?
    @ObservationIgnored private var claudeLoop: Task<Void, Never>?
    /// Claude Code sign-in, in memory only. Each read of the Keychain item can show a macOS prompt.
    @ObservationIgnored private var claudeCredentials: ClaudeCredentials?
    @ObservationIgnored private var claudeCredentialsReadAt: Date?
    /// The cached token was refused (401/403): read again, at most every `staleCredentialsRetry`.
    @ObservationIgnored private var claudeCredentialsRefused = false
    @ObservationIgnored private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Usage")

    func start() {
        guard codexLoop == nil else { return }
        codexLoop = Task { [weak self] in
            while !Task.isCancelled {
                let usage = await Task.detached { Self.readCodex() }.value
                self?.codex = usage
                try? await Task.sleep(for: Self.codexInterval)
            }
        }
        // The first Claude read comes from the app (when the setting is observed).
        claudeLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.claudeInterval)
                await self?.refreshClaude()
            }
        }
    }

    func stop() {
        codexLoop?.cancel()
        claudeLoop?.cancel()
        codexLoop = nil
        claudeLoop = nil
    }

    /// Reads Claude now (after the user turns it on).
    func refreshClaude() async {
        guard claudeEnabled() else {
            claude = nil
            claudeCredentials = nil
            claudeCredentialsReadAt = nil
            claudeCredentialsRefused = false
            return
        }
        var result: Result<AgentUsage, ClaudeProblem>
        if let cached = claudeCredentials, !claudeCredentialsRefused, !cached.isExpired {
            result = await Self.fetchClaude(with: cached)
            if case .failure(let problem) = result, problem.isRefused {
                // Claude Code may have renewed the token: read the new one now.
                claudeCredentialsRefused = true
                claudeCredentialsReadAt = nil
                result = await fetchClaudeWithStoredCredentials()
            }
        } else {
            result = await fetchClaudeWithStoredCredentials()
        }
        switch result {
        case .success(let usage):
            claude = usage
        case .failure(let problem):
            logger.notice("Claude usage: \(problem.message, privacy: .public)")
            // Keep the last numbers on a passing failure (rate limit, network).
            if problem.isPassing, var last = claude, !last.windows.isEmpty {
                last.problem = nil
                claude = last
            } else {
                claude = AgentUsage(agent: .claude, plan: claude?.plan, windows: [], updatedAt: .now, problem: problem.message)
            }
        }
    }

    /// Reads the sign-in (Keychain or file) and fetches with it. While the cached token is expired or
    /// refused, it reads at most every `staleCredentialsRetry`, so a stopped Claude Code does not cause
    /// a Keychain prompt every poll.
    private func fetchClaudeWithStoredCredentials() async -> Result<AgentUsage, ClaudeProblem> {
        let isStale = claudeCredentials.map { $0.isExpired || claudeCredentialsRefused } ?? false
        if isStale, let readAt = claudeCredentialsReadAt,
           Date.now.timeIntervalSince(readAt) < Self.staleCredentialsRetry {
            return .failure(ClaudeProblem(message: "Sign-in expired: start Claude Code"))
        }
        let loaded = await Task.detached { Self.loadClaudeCredentials() }.value
        claudeCredentialsReadAt = .now
        guard let loaded else {
            claudeCredentials = nil
            return .failure(ClaudeProblem(message: "Not signed in to Claude Code"))
        }
        if loaded.accessToken != claudeCredentials?.accessToken { claudeCredentialsRefused = false }
        claudeCredentials = loaded
        if claudeCredentialsRefused || loaded.isExpired {
            // Claude Code renews the token when it runs. We do not renew it: that would sign Claude Code out.
            return .failure(ClaudeProblem(message: "Sign-in expired: start Claude Code"))
        }
        let result = await Self.fetchClaude(with: loaded)
        if case .failure(let problem) = result, problem.isRefused { claudeCredentialsRefused = true }
        return result
    }

    // MARK: - Codex

    nonisolated static func readCodex(home: URL = CodexFiles.homeDirectory, now: Date = .now) -> AgentUsage? {
        for file in recentRollouts(in: home.appending(path: "sessions"), now: now).prefix(6) {
            guard let tail = readTail(of: file, bytes: 512 * 1024),
                  let result = CodexUsageParser.lastRateLimits(in: tail, now: now) else { continue }
            return AgentUsage(agent: .codex, plan: result.plan, windows: result.windows, updatedAt: result.readAt)
        }
        return nil
    }

    /// Rollouts of the last 8 days, newest first.
    nonisolated static func recentRollouts(in sessions: URL, now: Date) -> [URL] {
        let calendar = Calendar.current
        let fileManager = FileManager.default
        var files: [(URL, Date)] = []
        for dayOffset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions
                .appending(path: String(format: "%04d", parts.year ?? 0))
                .appending(path: String(format: "%02d", parts.month ?? 0))
                .appending(path: String(format: "%02d", parts.day ?? 0))
            let names = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in names where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((url, modified))
            }
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    nonisolated static func readTail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        // Drop the cut first line.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return Data(data)
    }

    // MARK: - Claude

    struct ClaudeProblem: Error {
        var message: String
        /// Rate limit or network: try again later and keep the old numbers.
        var isPassing = false
        /// The server refused the token (401/403).
        var isRefused = false
    }

    nonisolated struct ClaudeCredentials: Sendable {
        var accessToken: String
        var expiresAt: Date?
        var plan: String?

        var isExpired: Bool { expiresAt.map { $0 < .now } ?? false }
    }

    nonisolated static func fetchClaude(with credentials: ClaudeCredentials) async -> Result<AgentUsage, ClaudeProblem> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentLounge", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let windows = ClaudeUsageParser.parse(data) else {
                    return .failure(ClaudeProblem(message: "Unknown usage reply"))
                }
                return .success(AgentUsage(agent: .claude, plan: credentials.plan, windows: windows, updatedAt: .now))
            case 401, 403:
                return .failure(ClaudeProblem(message: "Sign-in expired: start Claude Code", isRefused: true))
            case 429:
                return .failure(ClaudeProblem(message: "Rate limited", isPassing: true))
            default:
                return .failure(ClaudeProblem(message: "HTTP \(status)", isPassing: true))
            }
        } catch {
            return .failure(ClaudeProblem(message: "Offline", isPassing: true))
        }
    }

    /// `{"claudeAiOauth":{"accessToken":"…","expiresAt":<ms>,"subscriptionType":"max",…}}`.
    nonisolated static func parseClaudeCredentials(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let oauth = root["claudeAiOauth"],
              let token = oauth["accessToken"]?.stringValue, !token.isEmpty else { return nil }
        var expiresAt: Date?
        if case .number(let millis)? = oauth["expiresAt"] { expiresAt = Date(timeIntervalSince1970: millis / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt, plan: oauth["subscriptionType"]?.stringValue)
    }

    nonisolated static func loadClaudeCredentials() -> ClaudeCredentials? {
        let file = ClaudeFiles.configDirectory.appending(path: ".credentials.json")
        if let data = try? Data(contentsOf: file), let credentials = parseClaudeCredentials(data) {
            return credentials
        }
        return readKeychainWithSecurityTool().flatMap(parseClaudeCredentials)
    }

    /// Claude Code writes the item with `/usr/bin/security add-generic-password -U`, so the item's
    /// access list trusts only `/usr/bin/security`. A direct `SecItemCopyMatching` from this app shows a
    /// macOS prompt, and each token renewal resets the access list. Reading through the same tool does
    /// not show a prompt.
    nonisolated static func readKeychainWithSecurityTool() -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // `-w` prints the value as hex when it is not plain text.
        if !text.hasPrefix("{"), let decoded = Data(hexString: text) { return decoded }
        return Data(text.utf8)
    }
}

private extension Data {
    nonisolated init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
