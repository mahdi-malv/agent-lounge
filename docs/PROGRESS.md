# Agent Lounge — Progress

Read `PLAN.md` first. At the end of each session:
1. Tick finished items in `PLAN.md` §8 and §9.
2. Add a log entry below (newest on top).
3. Update **Next step**.

## Next step

1. User check: grant Accessibility (right-click menu → "Grant Accessibility Access…"), then click ↗ on a Zed card
   with 2+ Zed windows open, and on a card whose app window is minimized. Tick the PLAN §9 M4 item.
2. User check (optional): interactive Codex in Ghostty through `scripts/codex-dev.sh` → card, needs-input on an
   approval prompt, ↗ focus. Codex app checks (PLAN §9 M5) need global hooks → do them with the M7 installer.
3. User check M6: allow notifications when macOS asks; open Settings (gear in panel) and look at the layout;
   wait for a needs-input banner and click it; try "Launch at login". Tick PLAN §9 M6 items.
4. User check M7: `make install`, open Settings → Hooks → Update (Claude) and Install (Codex), then `/hooks` in
   Codex to trust. Check the Codex app items in PLAN §9 M5 with the global hooks.
5. **Settings → Hooks → Update (Claude)**: the Claude PermissionRequest hook needs the 3600 s timeout
   (now 5 s, so a phone answer only works in the first 5 s). Then pair the phone again if it shows the pair
   screen (protocol v2 dropped v1 pairings; already done on the S26 in session 12).
6. User check M8 Mac side: Settings → Phone → turn on, look at the layout, "Pair a Phone…", Remove. When a real
   phone connects the first time, macOS may ask to allow incoming connections (firewall is on): allow.
7. User check M8 Android: Settings screen look, "Forget", remove the phone on the Mac (phone shows "removed"),
   Mac sleep / Wi-Fi change (reconnect), a day with background alerts on (battery).

## Log

### 2026-11-18 — Session 13: plan usage bar
- `UsageMonitor`: Codex `rate_limits` from the newest rollouts (every 30 s); Claude `GET /api/oauth/usage` with the
  Claude Code token (Keychain "Claude Code-credentials" or `~/.claude/.credentials.json`, every 3 min, opt-in
  because of the Keychain prompt). The token is never renewed by us.
- Panel `UsageBar` under the header; Settings → Panel toggles. Snapshot gets optional `usage` (old phones ignore it).
- Android: `AgentUsage` in the protocol, usage strip under the top app bar.
- Verified: Mac 130 tests, Android 32 tests, lint clean, panel bar rendered (light/dark).
- Not verified: live Claude API reply (shape from Claude Code's own client), Keychain prompt, phone strip on device.

### 2026-11-18 — Session 12: approvals, encryption, Ghostty prompts
- Live check of Claude's PermissionRequest hook (facts → PLAN §12): dialog shows while the hook runs; an `allow`
  from a slow hook closes it; the hook is not killed when the user answers first.
- Approvals: `lounge-hook` 0.3.0 waits for Claude PermissionRequest; `HTTPResponder` (held requests);
  `ApprovalCenter`; installer timeout 3600 s for that hook; phone `decide`; Settings toggle. Android: Allow /
  Deny on the card and on the notification (unlock required).
- Protocol v2 (PLAN §10): P-256 pairing with an HMAC proof of the code, AES-GCM box with a device secret,
  per-connection HKDF keys, AES-GCM frames with counters. Same test vectors in Swift and Kotlin. Device secrets in
  `phones.json` (0600). v1 pairings dropped.
- Prompts: `PromptService` types into the Ghostty terminal by tty (`input text` + `send key "enter"`);
  `RemoteCard.canPrompt`; phone prompt field on expanded Ghostty cards; `result` message back.
- Verified: Mac 123 tests, Android 28 tests, lint without errors. Live: test client allow → tool ran 0.6 s later;
  deny → Claude got the message. On the S26: Allow on the card, Deny from the notification (app in background),
  v2 pairing + encrypted session, Allow over v2, prompt "Reply with just the word PONG" into a new Ghostty
  window → Claude answered PONG. `phones.json` mode 0600.
- Not verified: approvals with the installed hook (needs Update in Settings), Codex (not held on purpose),
  prompts into a Codex TUI in Ghostty, the Automation permission prompt for a fresh install.

### 2026-11-18 — Session 11: M8 Android app
- User made the template project `AgentLoungeCompanion/` (now `android/`) (AGP 9.6, SDK 37, minSdk 24). Facts → PLAN §11.
- Built: protocol models, mDNS discovery, OkHttp WebSocket connection with backoff and address refresh,
  DataStore pairing + settings, alert notifications, foreground service for background alerts, Compose UI
  (pair, lounge cards with avatar + details, settings), planet launcher icon.
- Verified on a Galaxy S26 Ultra (Android 17) with the Mac Debug build: local network permission prompt,
  mDNS found the Mac, pairing with a code, live cards (this session with tasks and context), needs-input
  heads-up notification, done notification with the app in the background, stale needs-input notification
  cleared, notification tap opens and expands the card, service starts after a fast background.
- Fixed on device: crash when discovery stopped (NsdManager callback into a shut-down executor); service did not
  start when the app went to the background before settings loaded.
- Tests: 19 JVM unit tests pass (3 runs), lint without errors.
- Mac: phone access was turned on for the test and stays on (the phone is paired). Test sessions removed.
- Not verified: revoke from the Mac on the device (unit test only), reconnect after Mac sleep / IP change,
  battery use of the service, API 24–33 devices.

### 2026-11-18 — Session 10: M8 Mac side (phone access)
- New `AgentLounge/Remote/`: `RemoteProtocol` (messages, `RemoteCard`), `PairingBook` + `RemoteHandshake` (pure),
  `LANAddress` (local-peer check, LAN IPs), `LANServer` (NWListener + WebSocket + Bonjour), `RemoteHub` (glue,
  card stream from `Observations`, alerts from `AlertCenter.onAlert`). Protocol facts → PLAN §10.
- Settings → Phone: on/off, status (name + IP:port), pairing code with countdown, paired phones (connected /
  last seen, Remove). `NSLocalNetworkUsageDescription` added.
- Fixed during test: a peer that never finished the WebSocket handshake was not closed by the auth timeout.
- Verified: 109 unit tests pass. Live: Bonjour browse/resolve (`dns-sd`, TXT `v=1 id=…`); pair, hello, bad token,
  no pairing, wrong first message through a test WebSocket client on 127.0.0.1 and on the LAN IP; snapshot after
  auth and on change; needsInput + done alerts from synthetic hook events; raw TCP peer closed after 10 s.
- Reverted after test: `remote.enabled` off, test device removed. Phone access stays off until the user turns it on.
- Not verified: Settings → Phone look, a real phone (firewall prompt), revoke from the UI.

### 2026-11-18 — Session 9: Codex backfill
- No file links a running Codex to its thread (rollout not open; `logs_2.sqlite` has no thread id for the TUI).
  Link: `codex` process folder + start time → `threads` row in `~/.codex/state_5.sqlite` (read-only, SQLite3).
  Facts → PLAN §2 "Codex".
- `CodexBackfill` (pure): `resume <id>` first; else newest process in the folder that started before the thread;
  one card per process (newest thread); `resume --last` → thread active since start. Skips `app-server` etc.
  (the TUI starts a managed app-server daemon in the same folder). `-C` / `--cd` respected.
- `CodexStateDB`: newest `state_<n>.sqlite`, main threads only (no archived, no subagents).
- `ProcessInspector`: `allPIDs`, `arguments`, `currentDirectory`.
- `SessionMonitor`: Codex backfill at launch and every 60 s. Backfilled cards take state from the rollout
  (`inferredState`) until their first hook event.
- Verified: 98 unit tests pass. Live (interactive Codex TUI in a pty, no hooks, app started after it): card
  created with Ghostty host, PID, model, effort, branch, thread name; running → idle after the turn (context 24k);
  removed when the process ended.
- Not done: Codex app threads (no per-thread liveness).

### 2026-11-18 — Session 8: M7 installer and polish
- `OrderedJSON`: own JSON parser/writer that keeps key order and number text. Round trip of the real
  `~/.claude/settings.json` (and its backup) is byte-identical.
- `HookConfig` (pure): install / uninstall / status for Claude (17 events) and Codex (12 events); other hooks and
  keys untouched; reinstall changes nothing; todo env var only added when missing.
- `HookInstaller` (files): backup `<file>.agent-lounge-backup-<time>`, atomic write, symlinks followed, file mode
  kept, invalid JSON never written, empty Codex `hooks.json` removed on uninstall.
- Settings → Hooks section (status, Install / Update / Uninstall with confirm, backup path, Codex trust hint).
  Menu line "Hooks: Claude … · Codex …". Empty panel has a "Hooks and Settings…" button. `GET /debug/hooks`.
- App icon: ringed planet, moon and stars on a dark squircle (`AppIconView`, Android `ic_launcher_*.xml` draws the same art), PNGs via `make icon` (`-renderIconTo <dir>` dev flag).
- `make release`, `make install` (→ /Applications, then update hooks in Settings). `README.md`.
- Verified: 89 unit tests pass; Release build has `AppIcon.icns` and the personal signature; `/debug/hooks` →
  Claude "installed" (existing dev hooks match the Debug path), Codex "not installed".
- Not run: `make install` and the Codex install (they change /Applications and ~/.codex; left to the user).

### 2026-11-18 — Session 7: M6 alerts and settings
- `AlertRule` (pure): needs input / error on entry into the state; done only on Stop after running or needs input
  (no alert for new sessions, interrupts, resumes). `AlertCenter`: NSSound per kind (respects mute, max one sound
  per 1.5 s), notification per kind (`UNUserNotificationCenter`, no notification sound, click → focus card).
  Repeat guard: same kind per card once in 5 s. Router passes the state before each event.
- `Preferences`: per-kind `AlertSetting` (sound on/off, system sound name, notify), mute, pinned panel floats,
  auto-hide done cards (Never / 5–120 min), sources on/off (Claude CLI, Claude.app, Codex). Defaults: sound for all
  three (Glass / Tink / Basso), notify for needs input and error.
- Settings window (own `NSWindow` + SwiftUI `Form`): Alerts (with sound preview), Panel, Sources, General
  (launch at login via `SMAppService.mainApp`). Opens from the menu ("Settings…", ⌘,) and a gear in the panel header.
- Disabled sources: the store keeps the cards (they stay current) but hides them; no alerts.
- Auto-hide runs on the monitor tick; a hidden card returns on its next event.
- Verified: build without warnings, 78 unit tests pass. Live: synthetic hook events → "needsInput alert" on
  PermissionRequest, "done alert" on Stop, nothing on the others (unified log).
- Not verified: notification banner + click (needs the user's permission), settings window look, launch at login.

### 2026-11-18 — Session 6: M5 Codex adapter
- Codex CLI 0.169 is inside ChatGPT.app (not on PATH). Docs + real payloads → PLAN §2 "Codex".
- Captured payloads with session-only hooks (`codex -c hooks.<Event>=…`, `--dangerously-bypass-hook-trust`).
  No change to `~/.codex`.
- `CodexAdapter` (new `AgentEvent.Kind.interrupt` → idle). Activity for `apply_patch` (file names from the patch),
  `spawn_agent`, `wait_agent`, `request_user_input` (needs input). `update_plan` → task list.
- `CodexRolloutParser` (context tokens + real window size, model, effort, branch, last message, turn state).
  `TranscriptReader` picks the parser per agent; shared `JSONLLineBuffer`. Thread names from `session_index.jsonl`.
- Host `.codexApp` (ChatGPT.app, bundle id `com.openai.codex`); focus `codex://threads/<id>`. Badge "Codex app".
- `scripts/codex-dev.sh`: runs Codex with our hooks for one run.
- Verified E2E (`codex exec`, Ghostty): card created, host Ghostty, PID = codex process, activity
  "Running sleep 6; echo one", context 24k / 258k from the rollout, Stop, SessionEnd removed the card.
  68 unit tests pass.
- Not verified: Codex app path (hooks there need the global `hooks.json`), interactive PermissionRequest.
- Open: Codex backfill (rollout not held open by the process).

### 2026-11-18 — Session 5: M4 focus
- User removed cmux; main terminal is now Ghostty 1.4.0. Ghostty has AppleScript: `focus` the terminal whose
  `tty` matches → right tab/split, window raised, minimized window restored. Replaces the cmux socket plan.
- `FocusRoute` (pure): Claude.app `local_` id → `claude://code/continue?session=…`; Ghostty + tty → AppleScript;
  Zed → AX raise by project folder name; else → activate parent app + AX un-minimize.
- `FocusService` + `AccessibilityWindows`. Without Accessibility: plain activation, system prompt once per launch.
  Menu item "Grant Accessibility Access…". Unpinned panel closes on ↗.
- Fixed host detection: Zed session showed "cmux" (Zed started from cmux inherits `CMUX_*` and bundle id).
  Now the process tree decides (nearest known `<Name>.app`), env is fallback.
- Stable signing through git-ignored `local.mk` (personal Apple Development cert). TCC grants survive rebuilds.
- Dev route `POST /debug/focus` (body = card id).
- Verified live through `/debug/focus`: Claude.app card → Claude front; Zed card → Zed front; Ghostty card →
  Ghostty front, also from a minimized window. 56 unit tests pass.
- Not verified: Zed window choice and generic un-minimize with Accessibility granted (needs the user's grant).
- The cmux enum case and hook env keys stay (harmless; badge only).

### 2026-11-18 — Session 4: M3 real tile data
- Activity text per tool (`ToolActivity`): Reading/Editing/Writing <file>, Bash `description` (else "Running <cmd>"),
  search, fetch, subagent, MCP "server · tool". `AskUserQuestion` / `ExitPlanMode` → needs input.
- Tasks (`TaskBook`): live from PostToolUse(TaskCreate/TaskUpdate/TodoWrite) + TaskCreated/TaskCompleted hooks;
  transcript replay is the base; merge per task id, hooks win. Verified live: 0/2 "Drafting notes" → 1/2 "Reviewing notes".
- Transcript reader (actor, incremental, tail-only for files > 32 MB): model, context tokens, effort, branch, AI title,
  permission mode, last message, first/last time. Context limit heuristic (`ContextWindow`).
- `SessionMonitor`: 2 s tick (transcripts + PID liveness with start-time check), backfill at launch and every 60 s from
  `~/.claude/sessions` + process env (`KERN_PROCARGS2`) + ancestry. Hook-created cards take launch folder,
  start time and Claude.app id from the registry. Card title = "<launch folder> · <AI title>".
- Fixed: `procStart` is UTC (first backfill found 0 of 4 sessions).
- Inline markdown in subtitle and last message.
- Verified: all 4 running sessions backfilled with right host (3 cmux + 1 Claude.app with `local_…` id), model,
  context, branch, title, tty. `kill -9` of an agent → card removed within one tick. 50 unit tests pass.
- User agreed: `env.CLAUDE_CODE_ENABLE_TODO_TOOLS=1` added to `~/.claude/settings.json` (backup
  `settings.json.agent-lounge-backup-20261118-013410`). New sessions get Task tools → progress bars.

### 2026-11-18 — Session 3: M2 event pipeline
- `lounge-hook`: reads stdin, adds host info (env keys, ancestor process chain with path + tty, tty), POSTs
  `{v, source, sentAt, host, payload}` to `127.0.0.1:47821/events` with raw sockets (250 ms timeouts).
  Nothing on stdout, always exit 0. ~10 ms per call. App down → exits 0 at once.
- App: `EventServer` (NWListener, loopback only, main queue, one request per connection, 16 MB cap),
  `EventRouter`, `HookEnvelope`/`JSONValue`, `ClaudeAdapter` → `AgentEvent`, `SessionReducer` (pure state
  machine, PLAN §5), `SessionStore.apply`. Basic host detection (cmux / Zed / Claude.app / terminal) for the badge.
- Panel starts empty. Mocks only through right-click → "Add Mock Sessions". Menu shows server status.
- State rules added: `SessionStart(compact)` keeps `running`; 3 consecutive `PostToolUseFailure` → `error`;
  `Stop` resets the subagent count; idle subtitle "Ready for a prompt" when no message yet.
- Tests: `AgentLoungeTests` (Swift Testing, 25 tests: HTTP parser, adapter, reducer, store). `make test`.
- E2E verified with real `claude -p` (v2.1.327, haiku) + `build/dev/claude-hooks.json`: SessionStart →
  UserPromptSubmit → PreToolUse → PostToolUse → Stop → SessionEnd reach the store. Payload facts → PLAN §2.
- ↗ is still a no-op (M4).
- Dev hooks are now in the user's global `~/.claude/settings.json` (user agreed). Backup:
  `~/.claude/settings.json.agent-lounge-backup-20261118-010223`. Undo = restore it. The hooks point at the
  Debug build in `build/`; after `make clean` they fail (non-blocking) until the next `make build`.
- PLAN §9 M2 verified: our user-level hooks and cmux's `--settings` hooks both fire.

### 2026-11-17 — Session 2: M1 app shell
- Build: `make build` (XcodeGen → xcodebuild into `build/`), `make run` (also restarts the app).
  Dev flag: `open "…/Agent Lounge.app" --args -openPanelAtLaunch YES`.
- Layout (now under `macos/`): `AgentLounge/App` (AppKit shell), `AgentLounge/Model`, `AgentLounge/UI` (SwiftUI), `LoungeHook/` (stub).
  The generated `.xcodeproj` is git-ignored.
- Swift 6, default actor isolation `MainActor`, macOS 26. Ad-hoc signing (stable signing is needed before M4 Accessibility).
- Status item: sofa glyph + colored dot (most urgent state) + count. Right-click menu: pin, mute, reload mocks, quit.
- Panel: borderless non-activating `NSPanel`, height fits content (top edge fixed), max 80 % of screen.
  Unpinned: closes on outside click / Escape. Pinned: floating, drag by header, position saved.
- Tiles: compact row + expanded details (model, mode, branch, folder, elapsed, last event, subagents,
  context meter, last message, task list). Needs-input tile has a pulsing orange border.
- Avatar: own design (rounded critter with antenna), drawn in `Canvas`. Color per project (FNV hash),
  face per state. Respects Reduce Motion.
- `lounge-hook` is bundled at `Contents/Resources/bin/` and exits 0. `--version` works.
- Verified: clean build, no compiler warnings; tiles + avatars rendered in light and dark mode
  (offline `ImageRenderer`, no Screen Recording permission for screenshots); panel window geometry.
- Found: Thaw hides new status items (PLAN §2 "Menu bar"). Added an off-screen fallback position.
- Open checks (not tested by hand yet): status-item click toggle, right-click menu, pin + drag + relaunch,
  outside-click close, Escape, tile expand/hover, hide/delete buttons.
- ↗ (focus) is a no-op until M4: it only writes a log line. Clicks reach the handler (seen in the log).
  User chose to keep the plan order (M2 → M3 → M4).
