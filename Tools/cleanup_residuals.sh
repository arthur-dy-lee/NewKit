#!/usr/bin/env bash
# Cleanup residual NewKit.app copies and LaunchServices registrations.
#
# What it does:
#   1. Quits any running NewKit.
#   2. Deletes every NewKit.app on disk except /Applications/NewKit.app
#      (build artifacts, dist/staging, Xcode DerivedData copies, etc.)
#   3. Unregisters every NewKit-bundle-id path from LaunchServices except
#      /Applications/NewKit.app, so "Open With" stops listing dead copies.
#   4. Re-registers /Applications/NewKit.app fresh.
#   5. Best-effort unregister of phantom DMG mount records.
#   6. Restarts Finder + Dock so menus pick up the change.
#
# What it does NOT touch (and why):
#   * "Login Items" in System Settings (the SMAppService / BTM database).
#     There is no per-item CLI removal — `sfltool resetbtm` would nuke every
#     app's entry, not just NewKit's. If extra NewKit rows linger in
#     System Settings → General → Login Items, click each and press '−'.
#   * The single legitimate /Applications/NewKit.app and its Finder Extension.
#
# Setup (one-time):
#     chmod +x Tools/cleanup_residuals.sh
# Run:
#     Tools/cleanup_residuals.sh

set -euo pipefail

KEEP="/Applications/NewKit.app"
BUNDLE_ID="app.newkit.NewKit"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

echo "==> Quitting NewKit if running"
osascript -e "tell application \"NewKit\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -x NewKit 2>/dev/null || true

echo "==> Removing classic Login Items named NewKit (legacy mechanism)"
# Pre-Ventura "open at login" path. Ventura+ apps usually live in BTM (see
# bottom of this script) but a rogue legacy entry might still be there.
osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    set itemNames to (name of every login item)
    repeat with n in itemNames
        if (n as text) contains "NewKit" then
            delete login item n
        end if
    end repeat
end tell
APPLESCRIPT

echo "==> Finding NewKit.app copies on disk"
# bash 3 (macOS default) has no `mapfile`; collect into a string and feed to
# while-read. `find /` will hit Permission denied on system paths and exit
# nonzero — that's expected, so we shield the whole pipeline from `set -e`.
found_list=$({
    mdfind -name "NewKit.app" 2>/dev/null || true
    find / -maxdepth 6 -name "NewKit.app" -type d 2>/dev/null || true
} | sort -u || true)

removed=0
while IFS= read -r p; do
    if [[ -z "$p" ]]; then continue; fi
    # Keep the canonical install. /System/Volumes/Data/Applications/NewKit.app
    # is the APFS firmlink alias of /Applications/NewKit.app — same inode.
    if [[ "$p" == "$KEEP" ]] || [[ "$p" == "/System/Volumes/Data/Applications/NewKit.app" ]]; then
        continue
    fi
    # Skip dSYM-style false matches.
    if [[ "$p" == *.dSYM ]]; then
        continue
    fi
    if [[ -d "$p" ]]; then
        echo "  rm -rf $p"
        rm -rf "$p"
        removed=$((removed + 1))
    fi
    "$LSREG" -u "$p" >/dev/null 2>&1 || true
done <<< "$found_list"
echo "    removed $removed extra .app(s) on disk"

echo "==> Unregistering stale LaunchServices entries for $BUNDLE_ID"
# Walk the dump and pair "bundle id" headers with their "path" lines.
"$LSREG" -dump 2>/dev/null \
| awk -v keep="$KEEP" '
    /^bundle id:/    { id = $0 }
    /^path:/         {
        path = $0
        sub(/^[^:]+:[[:space:]]+/, "", path)
        sub(/[[:space:]]+\(0x[0-9a-fA-F]+\)$/, "", path)
        if (id ~ /NewKit/ && path !~ /\.appex$/ && path != keep) {
            print path
        }
    }
' | while IFS= read -r stale; do
    [[ -n "$stale" ]] || continue
    "$LSREG" -u "$stale" >/dev/null 2>&1 || true
    echo "    unregistered: $stale"
done

echo "==> Best-effort cleanup of phantom DMG mount records"
for stale in \
    "/private/tmp/newkit_dmg_mount" \
    "/Volumes/NewKit 0.1.0" \
    "/Volumes/NewKit 1.0.0" \
    "/Volumes/NewKit 1.1.0"; do
    "$LSREG" -u "$stale" >/dev/null 2>&1 || true
done

echo "==> Re-registering canonical $KEEP"
"$LSREG" -f "$KEEP"

echo "==> Refreshing Finder and Dock"
killall Finder >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

echo
echo "==> Final state"
remaining=$("$LSREG" -dump 2>/dev/null \
    | awk '/^bundle id:/{id=$0} /^path:/{path=$0; sub(/^[^:]+:[[:space:]]+/,"",path); sub(/[[:space:]]+\(0x[0-9a-fA-F]+\)$/,"",path); if (id ~ /NewKit/ && path !~ /\.appex$/) print path}')
echo "$remaining"
echo

echo "Done."
echo
echo "If System Settings → General → Login Items still shows extra NewKit"
echo "rows, remove them manually with the '−' button — CLI cannot reach the"
echo "per-item BTM API without nuking every other app's login entry."
