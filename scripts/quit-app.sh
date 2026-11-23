#!/bin/sh
# Stops a running Agent Lounge and waits until it is gone (5 s at most).
# `open` right after `pkill` can fail with "_LSOpenURLsWithCompletionHandler() failed with error -600".
set -eu

pkill -x "Agent Lounge" 2>/dev/null || exit 0
tries=0
while pgrep -x "Agent Lounge" >/dev/null 2>&1 && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
done
