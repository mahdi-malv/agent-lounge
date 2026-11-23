#!/bin/sh
# Starts the app. Tries again for a few seconds: macOS can refuse to start an app that has just quit
# or has just been replaced.
#
#   scripts/open-app.sh <path/to/App.app>
set -eu

app=$1
tries=0
until open "$app" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 5 ]; then
        # Last try, with the error shown.
        open "$app"
        exit $?
    fi
    sleep 1
done
