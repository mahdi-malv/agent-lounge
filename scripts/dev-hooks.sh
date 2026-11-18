#!/bin/sh
# Writes build/dev/claude-hooks.json: a Claude Code settings file that sends all hook
# events to Agent Lounge through the lounge-hook in the Debug build.
#
# Manual test:  claude --settings build/dev/claude-hooks.json
# The real installer (M7) merges the same hooks into ~/.claude/settings.json.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
hook="$root/build/DerivedData/Build/Products/Debug/Agent Lounge.app/Contents/Resources/bin/lounge-hook"
out="$root/build/dev/claude-hooks.json"

if [ ! -x "$hook" ]; then
    echo "lounge-hook not found. Run 'make build' first." >&2
    exit 1
fi

mkdir -p "$(dirname "$out")"
jq -n --arg command "'$hook' claude" '
  def handler: [{type: "command", command: $command, timeout: 5}];
  # PermissionRequest waits for an answer from the phone (PLAN §12).
  def approval_handler: [{type: "command", command: $command, timeout: 3600}];
  ["PreToolUse", "PostToolUse", "PostToolUseFailure"] as $tool_events
  | ["SessionStart", "UserPromptSubmit", "Notification", "SubagentStart", "SubagentStop",
     "TaskCreated", "TaskCompleted", "Stop", "StopFailure", "PreCompact", "PostCompact",
     "CwdChanged", "SessionEnd"] as $other_events
  | {hooks: (
      ($tool_events | map({key: ., value: [{matcher: "*", hooks: handler}]}) | from_entries)
      + {PermissionRequest: [{matcher: "*", hooks: approval_handler}]}
      + ($other_events | map({key: ., value: [{hooks: handler}]}) | from_entries)
    )}
' > "$out"
echo "$out"
