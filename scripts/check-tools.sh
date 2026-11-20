#!/bin/sh
# Checks that the build tools are there, so a missing tool gives a hint and not an xcodebuild error.
set -eu

fail=0
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
    echo "Xcode is missing. Install Xcode 26 or later, open it once, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    fail=1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is missing. Run:" >&2
    echo "  brew install xcodegen" >&2
    fail=1
fi
[ "$fail" -eq 0 ] || exit 1

# Xcode's build database can fail with "disk I/O error" in folders that macOS protects or syncs.
case "$PWD/" in
    "$HOME/Downloads/"* | "$HOME/Desktop/"* | "$HOME/Documents/"*)
        echo "Note: this folder is inside Downloads, Desktop or Documents. If the build fails with" >&2
        echo "'disk I/O error', move the folder (for example to ~/agent-lounge) and run 'make clean'." >&2
        ;;
esac
