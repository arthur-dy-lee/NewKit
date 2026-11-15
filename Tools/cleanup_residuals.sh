#!/usr/bin/env bash
# Compatibility entrypoint for the app's verified old-version cleanup.
# DRY_RUN=1 only scans; neither mode quits NewKit or restarts Finder/Dock.
set -euo pipefail

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    echo 'Usage: DRY_RUN=1 Tools/cleanup_residuals.sh [--scan-folder /path]'
    echo 'Without DRY_RUN=1, backs up configuration and moves verified older copies to Trash.'
    exit 0
fi

APP="${NEWKIT_APP:-/Applications/NewKit.app}"
PLIST="$APP/Contents/Info.plist"
[[ -x "$APP/Contents/MacOS/NewKit" && -f "$PLIST" ]] || {
    echo 'Install NewKit 1.4.3 or later first.' >&2; exit 1;
}
APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
case "$APP_ID" in
    com.codearthur.matrixapps.newkit|com.codearthur.matrixapps.newkit.debug) ;;
    *) echo 'The selected app is not NewKit.' >&2; exit 1 ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) echo 'Unsupported build number.' >&2; exit 1 ;;
esac
[[ "$BUILD_NUMBER" -ge 144 ]] || { echo 'Install NewKit 1.4.3 or later first.' >&2; exit 1; }
args=(--cleanup-old-versions)
[[ "${DRY_RUN:-0}" != 1 ]] || args+=(--dry-run)
exec "$APP/Contents/MacOS/NewKit" "${args[@]}" "$@"
