# Agent Lounge — Plan

A macOS menu-bar app that shows all running AI coding-agent sessions in one panel.
Each tile shows status and progress. A click on a tile focuses that session's window,
also when the window is minimized.

- Inspiration: https://www.instagram.com/p/Dfphrw3griE/.
  Use it for the idea only. Avatars and visual design are our own.
- Progress log and next step: `PROGRESS.md`.

## 1. Decisions (settled 2026-11-17)

| # | Topic | Decision |
|---|-------|----------|
| D1 | Sources in v1 | Claude Code CLI (cmux, Zed, other terminals), Claude Code in Claude.app, Codex CLI. All from v1. Use a source-adapter layer. |
| D2 | Data intake | Command hooks (main, real-time) + transcript files and cmux sessions file (backfill for sessions started before the app). |
| D3 | Tile content | As much as possible: compact row + expanded details (see §4). |
| D4 | UI surface | Menu-bar icon (count + status dot). Click opens the panel. Panel can be pinned as a floating always-on-top window. |
| D5 | States and actions | States: running, needs input, idle/done, error. Sound + highlight on alert, mute button. Actions: focus (↗), hide, delete. All behavior adjustable in settings. |
| D6 | Stack | Swift, SwiftUI + AppKit (`NSStatusItem`, `NSPanel`). Min macOS 26. Not sandboxed. Personal build, no App Store. |
| D7 | Mobile | Phase 2. Android only (Compose). First version LAN only. Remote later. |
| D8 | Docs | `docs/PLAN.md` + `docs/PROGRESS.md`. No nested folders. |
| D9 | Focus | Ghostty: AppleScript `focus` of the terminal with the session's tty. Zed: raise project window with AX. Claude.app: `claude://` deep link. Codex app: `codex://threads/<id>`. Other: parent-app activation + AX un-minimize. (cmux socket dropped 2026-11-18: user removed cmux.) |
| D10 | Event transport | Bundled CLI `lounge-hook` as a *command* hook → HTTP POST to `127.0.0.1`. |
| D11 | Lifecycle | Card lives while the agent process lives. Subagents = count on the parent card. |
| D12 | Installer | In-app Install / Uninstall of hooks, with backup. |
| D13 | Name | "Agent Lounge" (repo folder stays `claude-huddle`). |

## 2. Environment facts (found 2026-11-17)

Check again if a tool version changes.

### Where the user runs agents
- **Update 2026-11-18:** cmux is uninstalled. Main terminal is now **Ghostty** (v1.4.0). The cmux section below is history.
- Claude Code CLI v2.1.x (`~/.local/bin/claude`) in **Ghostty** and in **Zed** terminal (v1.28.1).
- Claude Code inside **Claude.app**.
- **Codex CLI** v0.169 at `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (sh wrapper →
  `…/codex-cli/CodexCLI.app/Contents/MacOS/codex`). Not on PATH since cmux is gone.
- **Codex desktop app** = `ChatGPT.app` (bundle id `com.openai.codex`, executable `ChatGPT`).
- No user hooks in `~/.claude/settings.json` yet.

### Claude Code hooks (https://code.claude.com/docs/en/hooks)
- Useful events: SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse,
  PostToolUseFailure, Notification, SubagentStart, SubagentStop, TaskCreated, TaskCompleted,
  Stop, StopFailure, PreCompact, PostCompact, CwdChanged, SessionEnd.
- Common stdin fields: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`,
  `effort`, `hook_event_name`, `agent_id`/`agent_type` (in subagents).
- Per event: tool events → `tool_name`, `tool_input`, `tool_use_id`. Stop → `last_assistant_message`.
  Notification → `message`, `title`, `notification_type`. SessionStart → `source`, `model`,
  `session_title`. SessionEnd → `reason`. TaskCreated → `task_id`, `task_subject`.
- Needs-input signal: `PermissionRequest` (immediate). Notification types `permission_prompt`
  (~6 s), `idle_prompt` (~60 s), `elicitation_dialog`.
- Task list: TaskCreate (`subject`, `activeForm`) + TaskUpdate (`taskId`, `status`:
  pending/in_progress/completed/deleted). Off by default on newer models →
  set `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`. Legacy TodoWrite only if `CLAUDE_CODE_ENABLE_TASKS=0`.
- Hook types: `command`, `http`, `mcp_tool`, `prompt`, `agent`. We use `command` (it can read env vars).
- Seen in real payloads (v2.1.327, 2026-11-18): `effort` is an object `{"level": "medium"}`. SessionStart in `-p` mode
  has only `source` (no `model`, no `session_title`) → model must come from the transcript (M3). Events carry `prompt_id`.
  Stop adds `background_tasks`, `session_crons`. PostToolUse adds `duration_ms`. All 17 hook event names above are accepted.
- Process: kernel name (`p_comm`) of the native CLI is the version (e.g. `2.1.326`); exe path is
  `~/.local/share/claude/versions/<ver>`. `__CFBundleIdentifier` is inherited from the host app (e.g. `com.cmuxterm.app`).

### Ghostty (checked 2026-11-18, v1.4.0)
- AppleScript (`Ghostty.sdef`): windows → tabs → terminals. Terminal has `id` (UUID, not `GHOSTTY_SURFACE_ID`),
  `tty` ("/dev/ttys002"), `working directory`, `pid`. `focus <terminal>` selects tab/split, raises the window,
  activates Ghostty and **restores a minimized window** (verified). No Accessibility needed.
- Needs Automation permission (Agent Lounge → Ghostty) + `NSAppleEventsUsageDescription` in Info.plist.
- Shell env: `TERM_PROGRAM=ghostty`, `GHOSTTY_SURFACE_ID`, `__CFBundleIdentifier=com.mitchellh.ghostty`.

### Inherited env (found 2026-11-18)
- Env vars are inherited by apps started from a shell. Zed launched from a cmux tab had all `CMUX_*` vars and
  `__CFBundleIdentifier=com.cmuxterm.app` in its terminals. Host detection uses the **process tree** first
  (nearest `<Name>.app/Contents/MacOS/` ancestor), env only as fallback.
- Claude.app ships the CLI at `…/Claude/claude-code/<ver>/<hash>/claude.app/Contents/MacOS/claude` (lower case);
  chain: claude → `Claude.app/Contents/Helpers/disclaimer` → `Claude.app/Contents/MacOS/Claude`.

### cmux (removed by the user 2026-11-18; kept for reference)
- CLI: `/Applications/cmux.app/Contents/Resources/bin/cmux`. Socket: `~/.local/state/cmux/cmux.sock`.
- `cmux tree --all --id-format both` → window/workspace/pane/surface, with `tty=ttysNNN`.
- Focus: `cmux focus-panel --panel <surface>` (socket method `surface.focus {surface_id}`),
  `select-workspace`, `focus-window`. API docs: https://cmux.com/docs/api
- Socket mode is `cmuxOnly` (`~/.config/cmux/cmux.json` → `automation.socketControlMode`).
  Must change to `password` for an outside app. Env overrides: `CMUX_SOCKET_MODE`, `CMUX_SOCKET_PASSWORD`.
- Shell env: `CMUX_SURFACE_ID` (= `CMUX_PANEL_ID`), `CMUX_WORKSPACE_ID` (= `CMUX_TAB_ID`),
  `CMUX_SOCKET_PATH`, `CMUX_CLAUDE_PID`, `CMUX_AGENT_LAUNCH_KIND`, `TERM_PROGRAM=ghostty`.
- cmux starts claude with `--settings ~/.cmuxterm/claude-settings/<hash>.json` (its own hooks).
  `claude` on PATH in cmux is a shim → `cmux-claude-wrapper`. Real args: `claude --session-id <uuid> --settings <file>`.
  cmux hook events: Notification, PermissionRequest, PostToolUse, PreToolUse, SessionEnd, SessionStart, Stop,
  StopFailure, SubagentStop, UserPromptSubmit.
- Shell env also has `CMUX_SOCKET_CAPABILITY` (a socket token). Check in M4 if it can replace `password` mode.
- `cmux sessions list --json` reads `~/.cmuxterm/claude-hook-sessions.json` (no socket needed):
  `session_id`, `pid`, `surface_id`, `workspace_id`, `cwd`, `transcript_path`, `runtime_status`.

### Zed
- No way to focus one terminal tab from outside (no AppleScript, no matching `zed://` route).
- Window title = project folder name (e.g. ".zshscripts"), seen through AX.
- Terminal env: `ZED_TERM=true`, `TERM_PROGRAM=zed`.
- Fallback: raise the Zed window with the project name in its title (AX). `zed <cwd>` may also work (not confirmed).

### Claude.app
- Focus a local session: `claude://code/continue?session=local_<uuid>` (or `claude://code/needs-input?session=…`).
- Map: `~/Library/Application Support/Claude/claude-code-sessions/<acct>/<org>/local_*.json` has
  `sessionId` (`local_…`) and `cliSessionId` (= hook `session_id`).
- Found in app code (`app.asar`), not in docs. Can break on app updates.

### Codex (checked 2026-11-18, CLI 0.169.0-alpha.11.1)
- Hooks: `~/.codex/hooks.json` or `[hooks]` in `config.toml` (feature `hooks = true` already on).
  Docs: https://developers.openai.com/codex/hooks.md (redirects to learn.chatgpt.com/docs/hooks.md).
  Same shape as Claude: `{hooks: {<Event>: [{matcher?, hooks: [{type: "command", command, timeout}]}]}}`.
- Trust: non-managed hooks run only after review (`/hooks` in the CLI, Settings > Hooks in the app). Trust is
  stored per hook hash in `config.toml` (`[hooks.state."<source>:<event>:i:j"] trusted_hash = "sha256:…"`).
  A changed command needs a new review. `--dangerously-bypass-hook-trust` skips review for one run.
- Session-only hooks: `codex -c 'hooks.Stop=[{hooks=[{type="command",command="…"}]}]'` works (used by
  `scripts/codex-dev.sh`).
- Events: SessionStart (`source`), SessionEnd (`reason` "other"; not for subagents; timeout max 3 s),
  UserPromptSubmit (`prompt`), PreToolUse / PostToolUse (`tool_name`, `tool_input`, `tool_use_id`,
  `tool_response`), PermissionRequest, SubagentStart/Stop (`agent_id`, `agent_type`), Stop
  (`last_assistant_message`), Interrupt, Pre/PostCompact, Pre/PostModelRequest (diagnostic). No
  PostToolUseFailure, Notification, Task events.
- Every event has `session_id` (= thread id, also in the rollout file name), `transcript_path`, `cwd`,
  `hook_event_name`, `model`. Turn events add `turn_id`, `permission_mode`. Subagent events use the parent's `session_id`.
- Tool names in hooks: shell and unified exec → `Bash` (`tool_input.command`), `apply_patch` (`tool_input.command`
  = patch text, `*** Update File: <path>`), `mcp__<server>__<tool>`, other function names. 0.169 runs tools
  through a JS "code mode" tool `exec` in the rollout, but hooks still see the inner tool (`Bash`). `exec` mode
  has no `update_plan`. Hosted tools (web search) fire no hooks.
- Stdout: plain text on SessionStart / UserPromptSubmit / SubagentStart goes into the model context. Empty stdout +
  exit 0 is fine on all events (verified: Stop "Completed").
- Hook process: direct child of the `codex` process (`p_comm` "codex"). No `CODEX_*` env vars; host env
  (`TERM_PROGRAM`, `__CFBundleIdentifier`, tty) is inherited as for Claude.
- Rollout `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread>.jsonl`: lines `{timestamp, ordinal, type, payload}`.
  `session_meta` (`cwd`, `git.branch`, `originator` "codex_exec" / "Codex Desktop", `source`), `turn_context`
  (`model`, `effort`, `approval_policy`), `event_msg` `token_count` (`info.last_token_usage.input_tokens` = context,
  `info.model_context_window` e.g. 258400), `task_started`, `task_complete` (`last_agent_message`), `turn_aborted`.
  The file is not kept open by the process (no PID → rollout link through open files).
- Thread names: `~/.codex/session_index.jsonl` (`{id, thread_name, updated_at}`, later lines win).
- State DB `~/.codex/state_5.sqlite` (WAL, held open by every codex process): table `threads` (`id`, `rollout_path`,
  `cwd` (real path), `created_at_ms`, `updated_at_ms`, `model`, `reasoning_effort`, `git_branch`, `name`, `archived`,
  `agent_path` (subagents), `source` "exec" / "vscode" (TUI)); `thread_spawn_edges` lists subagent threads. No PID.
  `logs_2.sqlite` has `process_uuid` "pid:<pid>:<uuid>" + `thread_id`, but TUI rows have no `thread_id` → not used.
- Backfill link (no PID in any file): `codex` process (cwd via `proc_pidinfo`, args via `KERN_PROCARGS2`) → thread
  in the same folder created after the process start; `resume <id>` names it (`CodexBackfill`).
- The TUI starts a managed `codex app-server --managed-daemon` (PPID 1, cwd = launch folder) that outlives it.
  Backfill skips `app-server` and other non-session subcommands.
- Codex app deep link `codex://threads/<thread id>` (from the app bundle, not documented; not tested yet).
- `notify` is used by Computer Use (SkyComputerUseClient). **Do not change it.**

### Claude Code local files (checked 2026-11-18, v2.1.326/327)
- `~/.claude/sessions/<pid>.json`: one per running process (CLI and Claude.app). Fields: `pid`, `sessionId`
  (follows `/clear`), `cwd` (launch folder), `startedAt` (ms), `procStart` (**UTC** text, "Tue Nov 17 22:23:35 2026"),
  `kind` ("interactive"), `entrypoint` ("cli" / "claude-desktop"), `hostSessionId` (Claude.app `local_…`, else ""),
  `name` (derived from folder), `status` ("busy" / "idle"), `statusUpdatedAt` (ms). Stale files remain → check PID + start.
- Transcript `~/.claude/projects/<cwd, non-alphanumerics → "-">/<sessionId>.jsonl`. Assistant lines: `message.model`,
  `message.usage` (context = input + cache_creation + cache_read), `message.stop_reason`, `gitBranch` ("HEAD" when no
  commit), `effort` (string), `isSidechain`. User lines: `toolUseResult` (TaskCreate → `{"task":{"id","subject"}}`),
  `permissionMode`. Entry `{"type":"ai-title","aiTitle":…}` = automatic title. Context window size is not written
  (global `model` "opus[1m]" → 1M heuristic).
- The transcript lags hooks: at PostToolUse the tool result is not written yet. Live task data must come from hooks
  (`tool_input` + `tool_response`); the transcript is the base for backfill.
- Other processes' env is readable with `sysctl KERN_PROCARGS2` (same user) → host facts for backfilled sessions.

### Code signing
- Ad-hoc signing changes the designated requirement every build → TCC (Accessibility, Automation) forgets the app.
- `make` reads git-ignored `local.mk` (`SIGN_IDENTITY` = cert SHA-1, `SIGN_TEAM` = cert OU). Then the requirement is
  `identifier … and certificate leaf[subject.CN] = …` and stays stable.

### Menu bar
- User runs **Thaw** (menu-bar manager). New status items start in its hidden section
  (button frame is off-screen, e.g. x = -4093). User must move Agent Lounge to the visible section.
- The panel falls back to the top-right of the main screen when the status item is off-screen.

### macOS focus (generic)
- PID → walk parents (`sysctl KERN_PROC`) until `NSRunningApplication(processIdentifier:)` is non-nil.
- `unhide()` + `activate()` (cooperative activation, `NSApp.yieldActivation(to:)`).
- AX: `AXUIElementCreateApplication(pid)` → windows → set `kAXMinimizedAttribute=false`,
  `kAXRaiseAction`, `kAXMainAttribute=true`. Needs Accessibility permission.

## 3. Architecture

```
agent (claude / codex)
  └─ hook: lounge-hook <source>      reads stdin JSON + env (TERM_PROGRAM, CMUX_*, ZED_TERM, tty, ppid)
        └─ POST http://127.0.0.1:<port>/events   (timeout ~200 ms, always exit 0, never block the agent)
              └─ Agent Lounge.app
                   ├─ EventServer (Network.framework)
                   ├─ Source adapters → normalized AgentEvent
                   ├─ SessionMonitor: transcripts (2 s tick), PID liveness, backfill (~/.claude/sessions)
                   ├─ SessionStore (state machine per session)
                   ├─ Focus service (Ghostty / Zed / Claude.app / generic)
                   ├─ Alerts (sound, notifications)
                   └─ UI: status item + panel + settings
```

- `lounge-hook`: Swift CLI target, bundled at `Agent Lounge.app/Contents/Resources/bin/lounge-hook`.
  The installer writes its absolute path into the hook config.
- Port: default **47821**, override with env `AGENT_LOUNGE_PORT` (hook + app) or `defaults write dev.agentlounge.AgentLounge port N` (app).
  Bind to `127.0.0.1` only in v1. Routes: `POST /events`, `GET /health`, dev aids `GET /debug/sessions`, `GET /debug/events`,
  `POST /debug/focus` (body = card id, same as ↗).
- Envelope (hook → app): `{v, source, sentAt, host, payload}`. `host` = env facts + `processes` (ancestor chain: pid, ppid, name, path, tty) + `tty`.
  Card id = `<source>:<session_id>`.
- Normalized event: `source`, `sessionId`, `event`, `timestamp`, `cwd`, `transcriptPath`, raw payload,
  `host` (`termProgram`, `cmuxSurfaceId`, `cmuxWorkspaceId`, `tty`, `pid`, `ppid`).
- PID liveness: poll each session's agent PID every 2 s, compare process start time (PID reuse). Verified with `kill -9`.

## 4. Tile spec

**Compact row** (like the reference):
- Avatar: own character design. Color per project. Face per state (working, needs input "!", idle, error).
- Title: `session_title` or repo folder name.
- Subtitle: current activity from the last tool, e.g. "Editing `Foo.kt`", "Running `gradlew test`", "Reading …".
- Progress: `done/total` + active task `activeForm`. Indeterminate bar when no task list.
- Host badge: cmux / Zed / Claude.app / Codex / other.
- Buttons: ↗ focus, hide, delete.

**Expanded** (click or hover):
- Model, effort, permission mode.
- Git branch, cwd.
- Elapsed time, time since last event.
- Subagent count.
- Token / context use (from transcript).
- Last assistant message.
- Full task list.

## 5. State and lifecycle

- States: `running`, `needsInput`, `idle` (done), `error`.
  - running: UserPromptSubmit, PreToolUse, PostToolUse.
  - needsInput: PermissionRequest, Notification (`permission_prompt`, `idle_prompt`, `elicitation_dialog`).
  - idle: Stop.
  - error: StopFailure, PostToolUseFailure (if repeated).
- Card removed on SessionEnd or when the PID is gone.
- **Hide**: card returns on the session's next event.
- **Delete**: card gone for the rest of that session.
- No action kills an agent.

## 6. Settings

Window: right-click menu "Settings…" or the gear in the panel header (own `NSWindow`; the SwiftUI
`Settings` scene cannot be opened reliably from an LSUIElement app).

- Sound per event type (needs input, done, error) + sound choice. Global mute (also the panel button).
- macOS notifications on/off.
- Panel always on top on/off.
- Auto-hide done cards after N minutes.
- Source on/off: Claude CLI, Claude.app, Codex.
- Launch at login (`SMAppService`).
- ~~cmux socket password (Keychain)~~ (cmux removed).

## 7. Installer

- Claude: merge hooks into `~/.claude/settings.json` (backup first). Set `env.CLAUDE_CODE_ENABLE_TODO_TOOLS=1`.
- Codex: add hooks to `~/.codex/hooks.json` (backup first). Tell the user to trust them in Codex (`/hooks`).
  Events: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse,
  SubagentStart, SubagentStop, Stop, Interrupt, PreCompact, PostCompact. Command: `'<lounge-hook>' codex`, timeout 5.
- Do not touch Codex `notify`.
- Uninstall removes only our entries.
- Automation permission for Ghostty is asked by macOS on the first focus.
- Request Accessibility permission with a clear explanation.
- Done in M7: Settings → Hooks (Install / Update / Uninstall, with a confirm dialog). Our entries are found by
  "lounge-hook" in the command. Edits keep key order and number text (`OrderedJSON`, output like
  `JSON.stringify(v, null, 2)` + newline; round trip of the real `settings.json` is byte-identical).
  Invalid JSON is never written. Symlinks followed, file mode kept. Reinstall = no change. Status "outdated" when
  the hook path differs (app moved). The todo env var is removed on uninstall only if we added it.
  Codex `hooks.json` is deleted on uninstall when nothing else is left.

## 8. Milestones

### M1 — App shell
- [x] Xcode project: app target (LSUIElement, not sandboxed) + `lounge-hook` CLI target. XcodeGen (`project.yml`, `make build` / `make run`).
- [x] Status item with count + status dot.
- [x] Panel (`NSPanel`): open from status item, pin as floating.
- [x] Tile view (compact + expanded) with mock data, all four states.
- [x] Avatar component (color + face per state).

### M2 — Event pipeline (Claude CLI)
- [x] Local HTTP server on `127.0.0.1`.
- [x] `lounge-hook`: stdin + env → POST, timeout, always exit 0.
- [x] Normalized event model + Claude adapter.
- [x] SessionStore state machine.
- [x] Manual hook config for testing (`make dev-hooks` → `claude --settings build/dev/claude-hooks.json`).

### M3 — Real tile data
- [x] Tool → activity text.
- [x] Task progress (TaskCreate/TaskUpdate, TodoWrite fallback).
- [x] Transcript reader: model, tokens/context, last message.
- [x] Git branch, elapsed time, subagent count.
- [x] Lifecycle: PID liveness, SessionEnd, hide, delete.
- [x] Backfill from transcripts + `~/.claude/sessions` (replaces the cmux sessions file: it covers every host).

### M4 — Focus
- [x] Host detection: process tree first, env fallback.
- [x] Ghostty: AppleScript `focus` by tty (replaces the cmux socket client; cmux removed).
- [x] Zed: AX raise by project window title (without Accessibility: app activation only).
- [x] Generic: parent-PID walk + activate + un-minimize (AX).
- [x] Accessibility permission onboarding (prompt on first need + menu item).
- [x] Stable code signing (`local.mk`).

### M5 — More sources
- [x] Claude.app: `local_` id from `~/.claude/sessions` (`hostSessionId`) → `claude://code/continue?session=…` (done in M4).
- [x] Codex adapter (hooks + rollout transcript + thread names). Dev: `scripts/codex-dev.sh`.
- [x] Codex app host (`ChatGPT.app`) + focus via `codex://threads/<id>`.
- [x] Codex backfill (CLI sessions started before the app): running `codex` processes + `state_5.sqlite` threads.
  State follows the rollout until the first hook event. Codex app threads are not backfilled (one app-server, no
  per-thread liveness).

### M6 — Alerts and settings
- [x] Sounds per event, mute. Alert on entry into needs input / error, and on Stop after running (done).
  Same alert per card at most once in 5 s; one sound per 1.5 s.
- [x] macOS notifications (`UNUserNotificationCenter`, permission asked when a notify setting is on). Click → focus.
- [x] Settings window (all §6 items). Disabled sources: cards kept but not shown, no alerts.

### M7 — Installer and polish
- [x] Install / Uninstall with backups (§7). Menu line shows hook status; empty panel links to Settings.
- [ ] ~~cmux setup guide in app~~ (cmux removed).
- [x] App icon (`AppIconView`, rendered by `make icon`), local signing (`local.mk`), `make release` / `make install`,
  `README.md`.

### M8 — Phase 2: Android (LAN only)
- [x] Mac: optional LAN bind, Bonjour `_agentlounge._tcp`, WebSocket stream, pairing code → token.
  Protocol: §10.
- [x] Android (Compose): discover, pair, read-only cards, notifications on needs input / done / error. §11.
- [x] Phone answers Claude permission requests; phone types prompts into Ghostty sessions; encrypted protocol v2 (§10, §12).
- Later: remote access (Tailscale), PAKE for pairing, prompts for other hosts.

## 9. Open assumptions (verify in the named milestone)

- [x] M2: user hooks in `~/.claude/settings.json` run together with cmux's `--settings` hooks.
  Verified 2026-11-18: one session reached Agent Lounge and cmux's registry. Settings edits also reload live
  in running sessions.
- [ ] M5: Claude Code inside Claude.app runs user hooks from `~/.claude/settings.json`.
- [x] M3: `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` makes Task tools appear on the current model.
  Verified 2026-11-18 (opus + haiku): default = only `TaskStop`; with the var = TaskCreate/Get/List/Update/Stop.
  `CLAUDE_CODE_ENABLE_TASKS=0` does not bring back TodoWrite.
- [ ] M4: `zed <cwd>` raises the existing window (else AX only). Not needed: AX title match is used.
- [ ] M4: Zed AX window raise and generic un-minimize with Accessibility granted (code done, not verified live).
- [ ] M5: Codex app runs hooks from `~/.codex/hooks.json` for its threads, and `codex://threads/<id>` opens the thread.
  Liveness: one app-server process hosts all threads → cards live until SessionEnd or app quit.
- [ ] M5: interactive Codex CLI sends PermissionRequest (only `exec` with bypass was tested).
- [ ] M7: Codex hooks from the installer run after `/hooks` trust (12 entries), and `make install` +
  Update keeps hooks working from `/Applications`.
- [ ] M6: notification banner shows and its click focuses the agent (permission prompt needs the user).
- [ ] M8: Settings → Phone layout (window height with the new section), Pair / Remove buttons, macOS firewall
  prompt for incoming connections when a real phone connects (firewall is on).
- [ ] M6: launch at login from a Debug build in `build/` (SMAppService registers that path).
- [ ] M5: `claude://code/continue` link still works on the installed Claude.app version.
  2026-11-18: the link opens Claude.app (front app = Claude). Session switch not checked by eye yet.

## 10. Phone protocol v2 (M8)

Separate listener, never the hook server. Off by default (Settings → Phone, key `remote.enabled`).

- Listener: all interfaces, port **47822** (env `AGENT_LOUNGE_LAN_PORT` or `defaults write … lanPort N`).
  WebSocket (`NWProtocolWebSocket`), TCP keepalive ~1 min. Peers outside loopback / private / link-local
  ranges are refused (`LANAddress.isLocal`; CGNAT 100.64/10 too, so Tailscale needs a change later).
- Bonjour: `_agentlounge._tcp`, name = computer name, TXT `v=2`, `id=<serverId>` (UUID in `remote.serverId`).
- Crypto (`PhoneCrypto.swift` / `PhoneCrypto.kt`, same test vectors on both sides):
  - Pairing: phone P-256 key + `proof = HMAC-SHA256(code, pub)` (the code is never sent). Mac checks the proof,
    `pairKey = HKDF-SHA256(ECDH, salt: code, info "agentlounge v2 pair")`, replies with its public key and
    `box = AES-GCM(pairKey, {secret, deviceId, server, serverId})`, then closes. `secret` = 32 random bytes.
  - Connection: `hello {deviceId, nonce}` → `challenge {nonce}` (clear). Keys = HKDF(secret, phoneNonce + macNonce,
    info "agentlounge v2 session", 64): first 32 phone → Mac, last 32 Mac → phone. Then only binary frames:
    AES-256-GCM, nonce = 4 zero bytes + 8-byte counter (per direction, from 0, strict order), AAD "agentlounge v2".
    The phone's first frame is `{"type":"auth"}`; the Mac sends nothing secret before it.
  - Limit: an active attacker on the network during the 5-minute pairing window can brute-force the 6-digit
    code from the proof and sit in the middle. Passive listening never gets the secret. A PAKE would close this.
- Messages (JSON, `RemoteProtocol.swift`): clear `pair`/`paired`, `hello`/`challenge`, `error`. Encrypted: phone
  `auth`, `decide {requestId, allow}`, `prompt {cardId, text}`; Mac `welcome`, `snapshot` (all visible cards as
  `RemoteCard`, at most every 250 ms), `alert` (needsInput/done/error, with `approval` when one is open),
  `result {cardId, ok, reason}` (prompt), `error` (`revoked`).
- Mac storage: `~/Library/Application Support/Agent Lounge/phones.json` (mode 0600; device secrets). Not the
  Keychain: ad-hoc builds would ask for Keychain access after every rebuild. v1 devices (`remote.devices`) are
  dropped: phones pair again. Remove = revoke + close that phone's connections.
- `RemoteCard` has no PIDs or process data; last message cut to 2000 characters; `canPrompt` for Ghostty sessions.
- Dev aids: `GET /debug/remote` (status), `POST /debug/pair-code` (Debug builds; starts pairing, returns the code).

## 11. Android app (M8, `android/`)

- Gradle project made by the user from the Android Studio template: AGP 9.6 (built-in Kotlin 2.2.10), compileSdk/
  targetSdk 37, minSdk 24, package `wtf.mahdi.agentloungecompanion`. Build: `./gradlew -q --console=plain
  :app:installDebug`. Tests: `:app:testDebugUnitTest` (JVM; connection tests use OkHttp MockWebServer).
- Libraries: OkHttp 5 (WebSocket, ping 20 s), kotlinx.serialization 1.9, DataStore, lifecycle-viewmodel-compose.
  No DI framework, no navigation library (`AppContainer` in `AgentLoungeApp.kt`, `RootViewModel` routes).
- Android 17 (API 37) local network protection: `ACCESS_LOCAL_NETWORK` is a runtime permission (group
  NEARBY_DEVICES). Without it TCP connects to LAN IPs time out and mDNS fails. The app asks at launch
  (with POST_NOTIFICATIONS). Not using the system mDNS picker: background reconnects and address refresh need
  plain access. Source: developer.android.com/privacy-and-security/local-network-permission.
- Cleartext `ws://` allowed by `network_security_config.xml` (protocol v1). Backups excluded (token).
- Layers: `protocol/` (models, parse), `net/` (`MacDiscovery` = NsdManager, `LoungeSockets` = OkHttp),
  `core/LoungeConnection` (one socket while held by UI or service; backoff 1–30 s; after 2 failures mDNS lookup
  by `serverId` for a new IP; `badToken`/`revoked` → forget pairing), `notify/` (channels per alert kind,
  `LoungeService` = foreground service type `connectedDevice`, needs CHANGE_NETWORK_STATE), `ui/`.
- Connection holders: process in foreground ("ui") and the service ("service", setting "Alerts when the app is
  closed", default on). The service can only start while the app is in the foreground.
- Alert notifications: tag = card id, id = alert kind; cleared when the card no longer needs it. Tap → opens
  the app and expands that card.
- Same look as the Mac: avatar port (`ui/components/Avatar.kt`, draw-phase animation), same state colors and
  project palette (64-bit FNV-1a of the project name).
- NsdManager can post callbacks after unregistering: its executor must never be shut down (crash found on device).
- Input from the phone: approvals and Ghostty prompts (§12).

## 12. Approvals and prompts from the phone

Checked live 2026-11-18 (Claude Code interactive, pty + `--settings` hook):
- Claude shows its permission dialog **at the same time** as the `PermissionRequest` hook starts. A slow hook
  does not delay the dialog.
- A hook that prints `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  while the dialog is open closes it, and the tool runs. `deny` + `message` reaches the model.
- When the user answers in the terminal first, the hook is **not** killed: it runs until it ends or times out.
- Codex docs: Codex waits for hooks before it goes on → a waiting hook could hide its prompt. Codex is not held.

Design:
- `lounge-hook` (0.3.0): for Claude `PermissionRequest` (not AskUserQuestion / ExitPlanMode) it sends
  `X-Lounge-Wait: approval` and waits up to 3700 s. 200 + JSON → printed to stdout; 204 → no decision.
- Installer: Claude `PermissionRequest` hook timeout 3600 s (others 5 s). An install with 5 s shows "outdated".
- App: `EventServer` can hold a request (`HTTPResponder`). `ApprovalCenter` holds it when phone access and
  "Phones can answer permission requests" (default on) are on and at least one phone is paired. Released with
  204 on the next tool event of the same agent, on Stop / UserPromptSubmit / Interrupt / SessionEnd, when the hook
  goes away, or when phone access is turned off.
- Phone: Allow / Deny on the card and on the needs-input notification (unlock required for the actions).
- Prompts (`PromptService`): only Ghostty sessions with a tty. AppleScript `input text "<text>" to t` +
  `send key "enter" to t` for `first terminal whose tty is …` (no focus change). Refused while the card needs
  input (text + Enter would answer the dialog). Control characters removed, max 4000 characters.
  Error -1743 = no Automation permission for Ghostty.
