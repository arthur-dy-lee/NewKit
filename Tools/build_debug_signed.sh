#!/usr/bin/env bash
# Build and register a Developer ID signed Debug app with its own bundle ID.
# Use --install to put the grantable app at /Applications/NewKit Debug.app.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DERIVED="$ROOT/build/debug-signed"
APP="$DERIVED/Build/Products/Debug/NewKit.app"
EXTENSION="$APP/Contents/PlugIns/NewKitFinderExtension.appex"
INSTALL_APP='/Applications/NewKit Debug.app'
BUILD_LOG="$DERIVED/build.log"
IDENTITY="Developer ID Application: bozhu li (XVZHPD648U)"
TEAM_ID=XVZHPD648U
APP_ID=com.codearthur.matrixapps.newkit.debug
EXTENSION_ID=com.codearthur.matrixapps.newkit.debug.FinderExtension
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help)
            echo "Usage: Tools/build_debug_signed.sh [--install]"
            echo "  --install  Replace and register /Applications/NewKit Debug.app"
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
if ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
    echo "The signing certificate is unavailable: $IDENTITY" >&2
    exit 1
fi

xcodegen generate >/dev/null
mkdir -p "$DERIVED"
if ! xcodebuild -project NewKit.xcodeproj -scheme NewKit \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=YES build \
    >"$BUILD_LOG" 2>&1; then
    tail -n 80 "$BUILD_LOG" >&2
    exit 1
fi

[[ -d "$APP" && -d "$EXTENSION" ]] || {
    echo "Missing Debug app or Finder Extension in $APP" >&2; exit 1;
}
/usr/bin/codesign --verify --deep --strict "$APP"

verify_bundle() {
    local bundle="$1" expected_id="$2" details plist_id sign_id sign_team
    details=$(/usr/bin/codesign -dv --verbose=4 "$bundle" 2>&1)
    plist_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
    sign_id=$(sed -n 's/^Identifier=//p' <<<"$details")
    sign_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$details")
    if [[ "$plist_id" != "$expected_id" || "$sign_id" != "$expected_id" || "$sign_team" != "$TEAM_ID" ]] ||
       ! grep -Fxq "Authority=$IDENTITY" <<<"$details" ||
       grep -Fxq 'Signature=adhoc' <<<"$details"; then
        echo "Unexpected signature on $bundle:" >&2
        echo "$details" >&2
        exit 1
    fi
}

verify_bundle "$APP" "$APP_ID"
verify_bundle "$EXTENSION" "$EXTENSION_ID"

DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")
[[ "$DISPLAY_NAME" == 'NewKit Debug' ]] || {
    echo "Unexpected Debug display name: $DISPLAY_NAME" >&2; exit 1;
}

# Refuse to replace a running Debug app, since that leaves the old executable
# active even when the on-disk copy is new.
ACTIVE_APP="$APP"
if [[ "$INSTALL" -eq 1 ]]; then
    RUNNING_PIDS=$(swift -e 'import AppKit; print(NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).map { String($0.processIdentifier) }.joined(separator: ","))' "$APP_ID")
    if [[ -n "$RUNNING_PIDS" ]]; then
        echo "Quit NewKit Debug (PID $RUNNING_PIDS) before installing the new build." >&2
        exit 1
    fi

    BACKUP_DIR="$ROOT/dist/backup/debug"
    mkdir -p "$BACKUP_DIR"
    STAGING_DIR=$(mktemp -d "$ROOT/dist/.debug-install.XXXXXX")
    STAGED_APP="$STAGING_DIR/NewKit Debug.app"
    ditto "$APP" "$STAGED_APP"
    /usr/bin/codesign --verify --deep --strict "$STAGED_APP"
    verify_bundle "$STAGED_APP" "$APP_ID"
    verify_bundle "$STAGED_APP/Contents/PlugIns/NewKitFinderExtension.appex" "$EXTENSION_ID"

    BACKUP_APP=''
    INSTALL_SWAPPED=0
    rollback_install() {
        local status=$?
        if [[ "$status" -ne 0 && "$INSTALL_SWAPPED" -eq 1 ]]; then
            echo "Installation failed; restoring the previous Debug app." >&2
            "$LSREGISTER" -u "$INSTALL_APP" || true
            mv "$INSTALL_APP" "$BACKUP_DIR/NewKit Debug-failed-$(date '+%Y%m%d-%H%M%S')-$$.app.backup" || true
            if [[ -n "$BACKUP_APP" ]]; then
                mv "$BACKUP_APP" "$INSTALL_APP" || true
                "$LSREGISTER" -f "$INSTALL_APP" || true
            fi
        fi
    }
    trap rollback_install EXIT

    if [[ -e "$INSTALL_APP" ]]; then
        BACKUP_APP="$BACKUP_DIR/NewKit Debug-$(date '+%Y%m%d-%H%M%S')-$$.app.backup"
        mv "$INSTALL_APP" "$BACKUP_APP"
    fi
    if ! mv "$STAGED_APP" "$INSTALL_APP"; then
        [[ -z "$BACKUP_APP" ]] || mv "$BACKUP_APP" "$INSTALL_APP"
        echo "Could not move the signed Debug app into /Applications." >&2
        exit 1
    fi
    INSTALL_SWAPPED=1
    rmdir "$STAGING_DIR" || true

    /usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
    verify_bundle "$INSTALL_APP" "$APP_ID"
    verify_bundle "$INSTALL_APP/Contents/PlugIns/NewKitFinderExtension.appex" "$EXTENSION_ID"
    ACTIVE_APP="$INSTALL_APP"

    # Old ad-hoc Debug builds at other paths have the same bundle ID and may
    # win LaunchServices lookup even after this app is registered.
    while IFS= read -r old_path; do
        [[ -z "$old_path" || "$old_path" == "$INSTALL_APP" ]] && continue
        "$LSREGISTER" -u "$old_path" || true
    done < <("$LSREGISTER" -dump | awk -v wanted="$APP_ID" '
        /^[-]+$/ {
            if (identifier == wanted && path != "") print path
            path=""; identifier=""; next
        }
        /^path:[[:space:]]/ {
            path=$0
            sub(/^path:[[:space:]]+/, "", path)
            sub(/ \(0x[[:xdigit:]]+\)$/, "", path)
        }
        /^identifier:[[:space:]]/ {
            identifier=$0
            sub(/^identifier:[[:space:]]+/, "", identifier)
        }
        END { if (identifier == wanted && path != "") print path }
    ' | sort -u)

    "$LSREGISTER" -f "$INSTALL_APP"
    LS_PATH=$(swift -e 'import AppKit; print(NSWorkspace.shared.urlForApplication(withBundleIdentifier: CommandLine.arguments[1])?.path ?? "")' "$APP_ID")
    if [[ -z "$LS_PATH" || "$(realpath "$LS_PATH")" != "$(realpath "$INSTALL_APP")" ]]; then
        echo "LaunchServices resolves $APP_ID to $LS_PATH, expected $INSTALL_APP" >&2
        exit 1
    fi
    trap - EXIT
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
EXECUTABLE="$ACTIVE_APP/Contents/MacOS/NewKit"
echo "Debug app: $ACTIVE_APP"
echo "Display name / version: $DISPLAY_NAME $VERSION ($BUILD_NUMBER)"
echo "Bundle ID: $APP_ID"
echo "Signing identity: $IDENTITY"
echo "Team ID: $TEAM_ID"
echo "Executable SHA-256: $(shasum -a 256 "$EXECUTABLE" | cut -d ' ' -f 1)"
echo "Executable modified: $(date -r "$EXECUTABLE" '+%Y-%m-%d %H:%M:%S %z')"
if [[ "$INSTALL" -eq 1 ]]; then
    echo "LaunchServices: $LS_PATH"
    [[ -z "$BACKUP_APP" ]] || echo "Previous Debug app backup: $BACKUP_APP"
else
    echo "Install and register for Accessibility: Tools/build_debug_signed.sh --install"
fi
echo "Finder Extension: Developer ID signed; App Group sharing is unavailable in Debug."
echo "No app was launched or notarized."
