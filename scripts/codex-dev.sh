#!/bin/zsh
# Runs Codex CLI with Agent Lounge hooks for this run only (no change to ~/.codex).
#
#   scripts/codex-dev.sh [codex args…]        e.g.  scripts/codex-dev.sh exec "say hi"
#
# Hooks come from `-c hooks.<Event>=…` overrides. `--dangerously-bypass-hook-trust` skips the
# one-time hook review for this run only; the hooks are ours (lounge-hook in the Debug build).
# The real installer (M7) writes ~/.codex/hooks.json, which the user trusts once in Codex (/hooks).
set -eu

root=${0:A:h:h}
hook="$root/build/DerivedData/Build/Products/Debug/Agent Lounge.app/Contents/Resources/bin/lounge-hook"
if [[ ! -x $hook ]]; then
    echo "lounge-hook not found. Run 'make build' first." >&2
    exit 1
fi

codex=${CODEX_BIN:-$(command -v codex || echo /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex)}

handler="{type=\"command\",command=\"'$hook' codex\",timeout=5}"
args=()
for event in SessionStart SessionEnd UserPromptSubmit PreToolUse PermissionRequest PostToolUse \
    SubagentStart SubagentStop Stop Interrupt PreCompact PostCompact; do
    args+=(-c "hooks.$event=[{hooks=[$handler]}]")
done

exec "$codex" --dangerously-bypass-hook-trust "${args[@]}" "$@"
