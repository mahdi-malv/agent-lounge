#!/bin/sh
# Packs an .app into a compressed DMG with an /Applications link for drag-to-install.
#
#   scripts/make-dmg.sh <path/to/App.app> <out.dmg>
set -eu

app=$1
out=$2
if [ ! -d "$app" ]; then
    echo "App not found: $app" >&2
    exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"

mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil create -quiet -volname "Agent Lounge" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out"
echo "$out"
