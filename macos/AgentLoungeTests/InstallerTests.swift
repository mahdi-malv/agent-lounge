import Foundation
import Testing
@testable import AgentLounge

struct OrderedJSONTests {
    @Test func roundTripKeepsOrderAndNumbers() throws {
        let text = #"""
        {
          "env": {
            "B": "2",
            "A": "1"
          },
          "model": "opus[1m]",
          "n": 1.50,
          "big": 12345678901234567890,
          "flags": [
            true,
            false,
            null
          ],
          "empty": {},
          "list": [],
          "text": "quote \" slash \\ tab \t line \n ü 😀 \u00e9"
        }
        """#
        let value = try OrderedJSON.parse(Data(text.utf8))
        #expect(value.members?.map(\.key) == ["env", "model", "n", "big", "flags", "empty", "list", "text"])
        #expect(value["text"]?.stringValue == "quote \" slash \\ tab \t line \n ü 😀 é")
        // `\u00e9` is written back as the character, like JSON.stringify does.
        #expect(value.prettyText() == text.replacingOccurrences(of: #"\u00e9"#, with: "é"))
    }

    @Test func surrogatePairsAndErrors() throws {
        #expect(try OrderedJSON.parse(Data(#""\ud83d\ude00""#.utf8)) == .string("😀"))
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(#"{"a": }"#.utf8)) }
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data("{} x".utf8)) }
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(#"{"a": 1,}"#.utf8)) }
    }

    @Test func subscriptSetAndRemove() {
        var value = OrderedJSON.object([.init(key: "a", value: .number("1"))])
        value["b"] = .bool(true)
        value["a"] = .string("x")
        #expect(value.members?.map(\.key) == ["a", "b"])
        value["a"] = nil
        #expect(value == .object([.init(key: "b", value: .bool(true))]))
    }
}

struct HookConfigTests {
    private let command = HookConfig.command(hookPath: "/Apps/Agent Lounge.app/Contents/Resources/bin/lounge-hook", agent: .claude)

    private func parse(_ text: String) -> OrderedJSON {
        try! OrderedJSON.parse(Data(text.utf8))
    }

    @Test func commandQuoting() {
        #expect(command == "'/Apps/Agent Lounge.app/Contents/Resources/bin/lounge-hook' claude")
        #expect(HookConfig.command(hookPath: "/a/it's/lounge-hook", agent: .codex) == "'/a/it'\\''s/lounge-hook' codex")
    }

    @Test func installKeepsOtherHooksAndKeys() {
        let before = parse("""
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "say done" } ] }
            ]
          },
          "theme": "dark"
        }
        """)
        let config = HookConfig.claude
        #expect(config.status(of: before, command: command) == .notInstalled)

        let after = config.installed(before, command: command)
        #expect(after.members?.map(\.key) == ["model", "hooks", "theme"])
        #expect(config.status(of: after, command: command) == .installed)
        #expect(after["hooks"]?.members?.count == config.events.count)
        let stop = after["hooks"]?["Stop"]?.arrayValue
        #expect(stop?.count == 2)
        #expect(stop?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue == "say done")
        #expect(after["hooks"]?["PreToolUse"]?.arrayValue?.first?["matcher"]?.stringValue == "*")
        #expect(after["hooks"]?["Stop"]?.arrayValue?.last?["matcher"] == nil)

        // Install twice = same result. Uninstall = the original.
        #expect(config.installed(after, command: command) == after)
        #expect(config.uninstalled(after) == before)
    }

    @Test func otherPathIsOutdated() {
        let config = HookConfig.codex
        let old = config.installed(.emptyObject, command: "'/old/lounge-hook' codex")
        #expect(config.status(of: old, command: "'/new/lounge-hook' codex") == .outdated)
        var partial = config.installed(.emptyObject, command: "'/new/lounge-hook' codex")
        partial["hooks"]?["Stop"] = nil
        #expect(config.status(of: partial, command: "'/new/lounge-hook' codex") == .outdated)
        #expect(config.uninstalled(old) == .emptyObject)
    }

    @Test func sharedGroupKeepsForeignHandler() {
        let before = parse("""
        {"hooks": {"Stop": [{"hooks": [
          {"type": "command", "command": "'/x/lounge-hook' claude"},
          {"type": "command", "command": "say done"}
        ]}]}}
        """)
        let after = HookConfig.claude.uninstalled(before)
        #expect(after["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.count == 1)
    }

    @Test func todoToolsEnv() {
        let added = HookConfig.withTodoTools(parse(#"{"env": {"X": "1"}}"#))
        #expect(added?["env"]?.members?.map(\.key) == ["X", "CLAUDE_CODE_ENABLE_TODO_TOOLS"])
        #expect(HookConfig.withTodoTools(added!) == nil)
        #expect(HookConfig.withoutTodoTools(added!) == parse(#"{"env": {"X": "1"}}"#))
        #expect(HookConfig.withoutTodoTools(HookConfig.withTodoTools(.emptyObject)!) == .emptyObject)
    }
}

struct HookInstallerTests {
    private func makeInstaller() throws -> (HookInstaller, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lounge-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hook = directory.appending(path: "lounge-hook")
        try Data("#!/bin/sh\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let name = "AgentLoungeTests.\(UUID().uuidString)"
        let installer = HookInstaller(
            hookPath: hook.path,
            claudeSettings: directory.appending(path: "claude/settings.json"),
            codexHooks: directory.appending(path: "codex/hooks.json"),
            defaults: UserDefaults(suiteName: name)!
        )
        return (installer, directory)
    }

    @Test func claudeInstallBacksUpAndUninstallRestores() throws {
        let (installer, directory) = try makeInstaller()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = installer.claude.fileURL
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try Data(original.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)

        let change = try installer.install(.claude)
        #expect(change.changed)
        #expect(try String(contentsOf: change.backupURL!, encoding: .utf8) == original)
        #expect(try installer.status(.claude).get() == .installed)
        let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try installer.install(.claude).changed == false)

        try installer.uninstall(.claude)
        #expect(try String(contentsOf: settings, encoding: .utf8) == original)
    }

    @Test func codexCreatesAndRemovesFile() throws {
        let (installer, directory) = try makeInstaller()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try installer.status(.codex).get() == .notInstalled)
        let change = try installer.install(.codex)
        #expect(change.backupURL == nil)
        #expect(try installer.status(.codex).get() == .installed)
        try installer.uninstall(.codex)
        #expect(!FileManager.default.fileExists(atPath: installer.codex.fileURL.path))
    }

    @Test func invalidFileIsNeverWritten() throws {
        let (installer, directory) = try makeInstaller()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = installer.codex.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: url)
        #expect(throws: HookInstaller.InstallError.self) { try installer.install(.codex) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ broken")
    }
}
