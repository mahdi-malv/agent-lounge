import Foundation

/// A running Codex CLI process (backfill input).
nonisolated struct CodexProcess: Equatable, Sendable {
    var pid: Int32
    /// Unix seconds.
    var startTime: Double
    var workingDirectory: String
    /// `argv`, `argv[0]` first.
    var arguments: [String]
}

/// Links running Codex CLI processes to their threads (PLAN M5 "Codex backfill").
///
/// The rollout file is not kept open, and the state database has no PID. So the link is by folder and time:
/// 1. `codex resume <id>` names the thread.
/// 2. A thread belongs to the newest process in its folder that started before the thread was created.
///    One card per process: its most recently updated thread (`/new` makes a new thread).
/// 3. Else (`resume --last`, picker): the most recently updated free thread in the folder since the start.
nonisolated enum CodexBackfill {
    /// Clock slack between process start and thread creation.
    static let slack: Double = 2

    /// Subcommands that are not agent sessions (servers and tools).
    static let nonSessionCommands: Set<String> = [
        "app-server", "exec-server", "mcp-server", "mcp", "login", "logout", "completion",
        "sandbox", "debug", "apply", "features", "cloud", "help", "doctor",
    ]

    struct Match: Equatable, Sendable {
        var process: CodexProcess
        var thread: CodexThreadRecord
    }

    static func match(processes: [CodexProcess], threads: [CodexThreadRecord]) -> [Match] {
        let processes = processes.filter(isSession)
        let threadsByID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var assigned: [Int32: CodexThreadRecord] = [:]
        var claimed: Set<String> = []

        func assign(_ thread: CodexThreadRecord, to process: CodexProcess) {
            assigned[process.pid] = thread
            claimed.insert(thread.id)
        }

        // 1. Explicit resume id.
        for process in processes {
            guard let id = resumedThreadID(process.arguments), let thread = threadsByID[id] else { continue }
            assign(thread, to: process)
        }

        // 2. Created after the process started.
        for thread in threads.sorted(by: { $0.updatedAt > $1.updatedAt }) where !claimed.contains(thread.id) {
            let owner = processes
                .filter { directory(of: $0) == thread.cwd && $0.startTime <= thread.createdAt + slack }
                .max { $0.startTime < $1.startTime }
            guard let owner, assigned[owner.pid] == nil else { continue }
            assign(thread, to: owner)
        }

        // 3. Resumed without an id: active in the folder since the start.
        for process in processes.sorted(by: { $0.startTime > $1.startTime }) where assigned[process.pid] == nil {
            let folder = directory(of: process)
            let since = process.startTime - slack
            let free = threads.filter { thread in
                !claimed.contains(thread.id) && thread.cwd == folder && thread.updatedAt >= since
            }
            if let thread = free.max(by: { $0.updatedAt < $1.updatedAt }) { assign(thread, to: process) }
        }

        return processes.compactMap { process in
            assigned[process.pid].map { Match(process: process, thread: $0) }
        }
    }

    static func isSession(_ process: CodexProcess) -> Bool {
        guard let command = subcommand(process.arguments) else { return true }
        return !nonSessionCommands.contains(command)
    }

    /// First argument that is not an option or an option value (`-c key=value`, `-C dir`, …).
    static func subcommand(_ arguments: [String]) -> String? {
        positionalArguments(arguments).first
    }

    /// `codex resume <id>` or `codex exec resume <id>`.
    static func resumedThreadID(_ arguments: [String]) -> String? {
        let positional = positionalArguments(arguments)
        guard let index = positional.firstIndex(of: "resume"), index + 1 < positional.count else { return nil }
        let candidate = positional[index + 1]
        return UUID(uuidString: candidate) != nil ? candidate.lowercased() : nil
    }

    /// Thread folder: `-C` / `--cd` relative to the process folder, else the process folder.
    static func directory(of process: CodexProcess) -> String {
        var value: String?
        var iterator = process.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "-C" || argument == "--cd" {
                value = iterator.next()
            } else if argument.hasPrefix("--cd=") {
                value = String(argument.dropFirst(5))
            }
        }
        guard let value, !value.isEmpty else { return process.workingDirectory }
        let base = URL(fileURLWithPath: process.workingDirectory, isDirectory: true)
        let path = URL(fileURLWithPath: value, relativeTo: base).standardizedFileURL.path
        // realpath, not `resolvingSymlinksInPath` (that one drops "/private" from "/private/tmp").
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Options that take a value as the next argument (Codex CLI 0.169).
    private static let optionsWithValue: Set<String> = [
        "-c", "--config", "-C", "--cd", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
        "-a", "--ask-for-approval", "-i", "--image", "--add-dir", "--enable", "--disable", "--local-provider",
    ]

    private static func positionalArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--" { break }
            if argument.hasPrefix("-") {
                if optionsWithValue.contains(argument) { _ = iterator.next() }
                continue
            }
            result.append(argument)
        }
        return result
    }
}
