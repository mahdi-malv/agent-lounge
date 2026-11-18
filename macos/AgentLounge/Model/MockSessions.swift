import Foundation

/// Sample cards for M1. Covers all four states, with and without a task list.
enum MockSessions {
    static func make(now: Date = .now) -> [AgentSession] {
        let home = NSHomeDirectory()
        return [
            AgentSession(
                id: "mock-running",
                agent: .claude,
                host: .cmux,
                state: .running,
                cwd: "\(home)/code/lounge-app",
                startedAt: now - 25 * 60,
                lastEventAt: now - 4,
                title: "Lounge · app shell",
                gitBranch: "main",
                activity: "Editing PanelController.swift",
                tasks: [
                    AgentTask(id: "1", subject: "Create Xcode project", activeForm: "Creating Xcode project", status: .completed),
                    AgentTask(id: "2", subject: "Add status item", activeForm: "Adding status item", status: .completed),
                    AgentTask(id: "3", subject: "Build floating panel", activeForm: "Building floating panel", status: .inProgress),
                    AgentTask(id: "4", subject: "Draw avatar", activeForm: "Drawing avatar", status: .pending),
                    AgentTask(id: "5", subject: "Add mock tiles", activeForm: "Adding mock tiles", status: .pending),
                ],
                model: "claude-opus-5-5",
                effort: "high",
                permissionMode: "acceptEdits",
                subagentCount: 2,
                context: ContextUsage(usedTokens: 84_000, limitTokens: 200_000),
                lastAssistantMessage: "The panel now opens under the status item. Next I will connect the pin button."
            ),
            AgentSession(
                id: "mock-needs-input",
                agent: .claude,
                host: .zed,
                state: .needsInput,
                cwd: "\(home)/code/android-shop",
                startedAt: now - 52 * 60,
                lastEventAt: now - 40,
                gitBranch: "feature/checkout",
                attention: "Allow Bash: ./gradlew test?",
                tasks: [
                    AgentTask(id: "1", subject: "Read checkout flow", status: .completed),
                    AgentTask(id: "2", subject: "Fix price rounding", status: .completed),
                    AgentTask(id: "3", subject: "Run unit tests", activeForm: "Running unit tests", status: .inProgress),
                    AgentTask(id: "4", subject: "Update snapshots", status: .pending),
                    AgentTask(id: "5", subject: "Write PR notes", status: .pending),
                ],
                model: "claude-sonnet-5-5",
                effort: "medium",
                permissionMode: "default",
                context: ContextUsage(usedTokens: 171_000, limitTokens: 200_000),
                lastAssistantMessage: "I need to run the unit tests to check the rounding fix."
            ),
            AgentSession(
                id: "mock-idle",
                agent: .claude,
                host: .claudeApp,
                state: .idle,
                cwd: "\(home)/notes/vault",
                startedAt: now - 2 * 3600,
                lastEventAt: now - 7 * 60,
                title: "Weekly notes cleanup",
                tasks: [
                    AgentTask(id: "1", subject: "Find duplicate notes", status: .completed),
                    AgentTask(id: "2", subject: "Merge duplicates", status: .completed),
                    AgentTask(id: "3", subject: "Fix broken links", status: .completed),
                    AgentTask(id: "4", subject: "Update index", status: .completed),
                ],
                model: "claude-opus-5-5",
                effort: "medium",
                permissionMode: "acceptEdits",
                context: ContextUsage(usedTokens: 46_000, limitTokens: 200_000),
                lastAssistantMessage: "Done. I merged 12 duplicate notes and fixed 31 broken links."
            ),
            AgentSession(
                id: "mock-error",
                agent: .codex,
                host: .cmux,
                state: .error,
                cwd: "\(home)/code/billing-api",
                startedAt: now - 14 * 60,
                lastEventAt: now - 90,
                gitBranch: "fix/invoice-totals",
                attention: "API error: rate limit reached",
                model: "gpt-5-codex",
                permissionMode: "on-request",
                lastAssistantMessage: "The request failed because of a rate limit."
            ),
            AgentSession(
                id: "mock-running-no-tasks",
                agent: .claude,
                host: .terminal("Ghostty"),
                state: .running,
                cwd: "\(home)/code/design-tokens",
                startedAt: now - 3 * 60,
                lastEventAt: now - 1,
                gitBranch: "main",
                activity: "Running npm test",
                model: "claude-haiku-5-5",
                effort: "low",
                permissionMode: "default",
                subagentCount: 1,
                context: ContextUsage(usedTokens: 12_000, limitTokens: 200_000)
            ),
        ]
    }
}
