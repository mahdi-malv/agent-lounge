#!/bin/sh
# Renders the app icon (AppIconView) into macos/AgentLounge/Assets.xcassets/AppIcon.appiconset.
# Run after a change to the icon artwork or the mascot, then `make build`.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/build/DerivedData/Build/Products/Debug/Agent Lounge.app/Contents/MacOS/Agent Lounge"
if [ ! -x "$app" ]; then
    echo "App not built. Run 'make build' first." >&2
    exit 1
fi
"$app" -renderIconTo "$root/macos/AgentLounge/Assets.xcassets/AppIcon.appiconset"
ls "$root/macos/AgentLounge/Assets.xcassets/AppIcon.appiconset"
