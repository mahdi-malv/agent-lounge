import AppKit
import SwiftUI

/// Settings section: install / update / uninstall the agent hooks (PLAN §7).
struct HooksSection: View {
    let installer: HookInstaller

    @State private var statuses: [AgentKind: Result<HookConfig.Status, Error>] = [:]
    @State private var pending: PendingAction?
    @State private var resultText: String?
    @State private var errorText: String?

    struct PendingAction: Identifiable {
        enum Kind { case install, uninstall }
        let agent: AgentKind
        let kind: Kind
        var id: String { "\(agent.rawValue)-\(kind)" }
    }

    var body: some View {
        Section {
            ForEach([AgentKind.claude, .codex], id: \.self) { agent in
                row(agent)
            }
            if let resultText {
                Text(resultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Hooks")
        } footer: {
            Text("Agents report to Agent Lounge through hooks. A backup of each file is made before a change. Only Agent Lounge entries are changed.")
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .alert(item: $pending) { action in
            Alert(
                title: Text(title(action)),
                message: Text(message(action)),
                primaryButton: action.kind == .uninstall ? .destructive(Text("Uninstall")) { run(action) } : .default(Text("Install")) { run(action) },
                secondaryButton: .cancel()
            )
        }
    }

    private func row(_ agent: AgentKind) -> some View {
        let status = statuses[agent]
        return LabeledContent {
            HStack(spacing: 8) {
                switch status {
                case .success(.installed):
                    Button("Uninstall…") { pending = PendingAction(agent: agent, kind: .uninstall) }
                case .success(.outdated):
                    Button("Update…") { pending = PendingAction(agent: agent, kind: .install) }
                    Button("Uninstall…") { pending = PendingAction(agent: agent, kind: .uninstall) }
                case .success(.notInstalled):
                    Button("Install…") { pending = PendingAction(agent: agent, kind: .install) }
                case .failure, nil:
                    Button("Reveal File") { reveal(agent) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent == .claude ? "Claude Code" : "Codex")
                Text(statusText(status, agent: agent))
                    .font(.caption)
                    .foregroundStyle(statusColor(status))
            }
        }
    }

    private func statusText(_ status: Result<HookConfig.Status, Error>?, agent: AgentKind) -> String {
        let file = (installer.target(agent).fileURL.path as NSString).abbreviatingWithTildeInPath
        switch status {
        case .success(.installed): return "Installed in \(file)"
        case .success(.outdated): return "Points to another copy of the app, or incomplete"
        case .success(.notInstalled): return "Not installed (\(file))"
        case .failure(let error): return error.localizedDescription
        case nil: return "Checking…"
        }
    }

    private func statusColor(_ status: Result<HookConfig.Status, Error>?) -> Color {
        switch status {
        case .success(.installed): .secondary
        case .success(.outdated): .orange
        case .failure: .red
        default: .secondary
        }
    }

    private func title(_ action: PendingAction) -> String {
        let name = action.agent == .claude ? "Claude Code" : "Codex"
        return action.kind == .install ? "Install hooks for \(name)?" : "Uninstall hooks for \(name)?"
    }

    private func message(_ action: PendingAction) -> String {
        let target = installer.target(action.agent)
        let file = (target.fileURL.path as NSString).abbreviatingWithTildeInPath
        switch (action.agent, action.kind) {
        case (.claude, .install):
            return "Adds \(target.config.events.count) hooks to \(file) and sets \(HookConfig.todoToolsEnvKey)=1 if it is not set. Running sessions pick them up at once."
        case (.codex, .install):
            return "Adds \(target.config.events.count) hooks to \(file). Codex runs them only after you trust them: run /hooks in Codex (or Settings > Hooks in the Codex app)."
        case (_, .uninstall):
            return "Removes the Agent Lounge hooks from \(file). Other hooks stay."
        }
    }

    private func run(_ action: PendingAction) {
        errorText = nil
        do {
            let change = action.kind == .install
                ? try installer.install(action.agent)
                : try installer.uninstall(action.agent)
            var text = change.changed ? "Done." : "No change needed."
            if let backup = change.backupURL {
                text += " Backup: \((backup.path as NSString).abbreviatingWithTildeInPath)"
            }
            if action.agent == .codex, action.kind == .install, change.changed {
                text += "\nNext: open Codex and trust the new hooks with /hooks."
            }
            resultText = text
        } catch {
            errorText = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        for agent in [AgentKind.claude, .codex] {
            statuses[agent] = installer.status(agent)
        }
    }

    private func reveal(_ agent: AgentKind) {
        NSWorkspace.shared.activateFileViewerSelecting([installer.target(agent).fileURL])
    }
}
