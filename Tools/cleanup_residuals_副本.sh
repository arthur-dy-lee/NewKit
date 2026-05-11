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
#     Tools/cleanup_residuals.sh                # do it
#     DRY_RUN=1 Tools/cleanup_residuals.sh      # show what would happen
#     NO_RESTART=1 Tools/cleanup_residuals.sh   # skip Finder/Dock restart

set -euo pipefail

KEEP="/Applications/NewKit.app"
BUNDLE_ID="app.newkit.NewKit"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
DRY_RUN="${DRY_RUN:-0}"
NO_RESTART="${NO_RESTART:-0}"

# Limited search roots — `find /` was slow and risky (external/network volumes,
# Time Machine snapshots). mdfind already covers Spotlight-indexed locations;
# these roots cover the unindexed places where build artifacts typically live.
SEARCH_ROOTS=(
    "$HOME/codes"
    "$HOME/Desktop"
    "$HOME/Downloads"
    "$HOME/Documents"
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$HOME/Library/Caches"
    "/tmp"
    "/var/folders"
    "/Applications"
)

if [[ ! -x "$LSREG" ]]; then
    echo "error: lsregister not found at $LSREG" >&2
    exit 1
fi

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Same-bundle test by inode (handles firmlink twin /System/Volumes/Data/...,
# trailing slashes, case-insensitive HFS, user-created symlinks).
keep_id="$(stat -f '%d:%i' "$KEEP" 2>/dev/null || true)"
is_keep() {
    local p="$1"
    [[ -n "$keep_id" ]] || return 1
    local pid
    pid="$(stat -f '%d:%i' "$p" 2>/dev/null || true)"
    [[ "$pid" == "$keep_id" ]]
}

DUMP="$(mktemp -t newkit_lsdump)"
trap 'rm -f "$DUMP"' EXIT

# Parse lsregister -dump: print paths whose CFBundleIdentifier == BUNDLE_ID,
# excluding .appex (the Finder Extension lives inside the canonical app).
# Records are separated by lines of dashes; within a record `path:` appears
# before `identifier:`, so buffer both and emit at record boundary.
parse_newkit_paths() {
    awk -v bid="$BUNDLE_ID" '
        function flush() {
            if (id == bid && path != "" && path !~ /\.appex$/) print path
            id = ""; path = ""
        }
        /^-{10,}/        { flush() }
        /^path:/         {
            p = $0
            sub(/^[^:]+:[[:space:]]+/, "", p)
            sub(/[[:space:]]+\(0x[0-9a-fA-F]+\)$/, "", p)
            path = p
        }
        /^[[:space:]]*identifier:/ {
            i = $0
            sub(/^[[:space:]]*[^:]+:[[:space:]]+/, "", i)
            id = i
        }
        END { flush() }
    ' "$DUMP"
}

echo "==> Quitting NewKit if running"
osascript -e "tell application \"NewKit\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x NewKit >/dev/null 2>&1 || break
    sleep 0.3
done
pkill -x NewKit 2>/dev/null || true

echo "==> Removing classic Login Items named NewKit (legacy mechanism)"
# Pre-Ventura "open at login" path. Ventura+ apps usually live in BTM but a
# rogue legacy entry might still be there. If Automation permission isn't
# granted, AppleScript exits with -1743; surface that hint at the end.
ls_err="$(mktemp -t newkit_ls_err)"
osascript <<'APPLESCRIPT' 2>"$ls_err" || true
tell application "System Events"
    set itemNames to (name of every login item)
    repeat with n in itemNames
        if (n as text) contains "NewKit" then
            delete login item n
        end if
    end repeat
end tell
APPLESCRIPT
login_items_blocked=0
if grep -q -- "-1743" "$ls_err" 2>/dev/null; then
    login_items_blocked=1
fi
rm -f "$ls_err"

echo "==> Finding NewKit.app copies on disk"
# bash 3 (macOS default) has no `mapfile`; collect into a string and feed to
# while-read. find/mdfind can each fail on permission-denied paths — shield
# the pipeline from `set -e`.
find_args=()
for r in "${SEARCH_ROOTS[@]}"; do
    [[ -d "$r" ]] && find_args+=("$r")
done
found_list=$({
    mdfind -name "NewKit.app" 2>/dev/null || true
    if (( ${#find_args[@]} > 0 )); then
        find "${find_args[@]}" -maxdepth 8 -name "NewKit.app" -type d 2>/dev/null || true
    fi
} | sort -u || true)

removed=0
while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -d "$p" ]] || continue
    [[ "$p" == *.dSYM ]] && continue
    if is_keep "$p"; then continue; fi
    printf '  rm -rf %q\n' "$p"
    run rm -rf "$p"
    run "$LSREG" -u "$p" >/dev/null 2>&1 || true
    removed=$((removed + 1))
done <<< "$found_list"
echo "    removed $removed extra .app(s) on disk"

echo "==> Dumping LaunchServices database"
"$LSREG" -dump >"$DUMP" 2>/dev/null || true

echo "==> Unregistering stale LaunchServices entries for $BUNDLE_ID"
while IFS= read -r stale; do
    [[ -n "$stale" ]] || continue
    if is_keep "$stale"; then continue; fi
    run "$LSREG" -u "$stale" >/dev/null 2>&1 || true
    printf '    unregistered: %q\n' "$stale"
done < <(parse_newkit_paths)

echo "==> Best-effort cleanup of phantom DMG mount records"
shopt -s nullglob
dmg_paths=( "/private/tmp/newkit_dmg_mount" /Volumes/NewKit\ * )
shopt -u nullglob
for stale in "${dmg_paths[@]}"; do
    run "$LSREG" -u "$stale" >/dev/null 2>&1 || true
done

echo "==> Re-registering canonical $KEEP"
if [[ -d "$KEEP" ]]; then
    run "$LSREG" -f "$KEEP"
else
    echo "    skipped: $KEEP does not exist"
fi

if [[ "$NO_RESTART" != "1" ]]; then
    echo "==> Refreshing Finder and Dock"
    run killall Finder >/dev/null 2>&1 || true
    run killall Dock   >/dev/null 2>&1 || true
else
    echo "==> Skipping Finder/Dock restart (NO_RESTART=1)"
fi

echo
echo "==> Final state"
"$LSREG" -dump >"$DUMP" 2>/dev/null || true
remaining="$(parse_newkit_paths)"
if [[ -z "$remaining" ]]; then
    echo "    (no NewKit paths registered — odd, but not fatal)"
else
    echo "$remaining"
fi
echo

echo "Done."
if (( login_items_blocked == 1 )); then
    echo
    echo "NOTE: AppleScript was blocked from reading Login Items (errAEEventNotPermitted -1743)."
    echo "      Grant your terminal app Automation access for System Events in"
    echo "      System Settings → Privacy & Security → Automation, then re-run."
fi
echo
echo "If System Settings → General → Login Items still shows extra NewKit"
echo "rows, remove them manually with the '−' button — CLI cannot reach the"
echo "per-item BTM API without nuking every other app's login entry."
