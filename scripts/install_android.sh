#!/bin/sh
# Builds the Android release APK, signed with the debug key, and installs it with adb.
#
#   scripts/install_android.sh [adb serial]     (serial is needed only with several devices)
#
# The release build uses the debug key when ANDROID_KEYSTORE_PATH is not set.
# We unset it here, so a CI keystore in your shell never gets used by mistake.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
apk="$root/android/app/build/outputs/apk/release/app-release.apk"

if ! command -v adb >/dev/null 2>&1; then
    echo "adb is missing. Install Android platform-tools." >&2
    exit 1
fi

unset ANDROID_KEYSTORE_PATH ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD

(cd "$root/android" && ./gradlew -q --console=plain :app:assembleRelease)

if [ ! -f "$apk" ]; then
    echo "APK not found: android/app/build/outputs/apk/release/app-release.apk" >&2
    exit 1
fi

if [ $# -ge 1 ]; then
    adb -s "$1" install -r "$apk"
else
    adb install -r "$apk"
fi
