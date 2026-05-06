#!/usr/bin/env bash
# Build NewKit.app in Release mode and package it as a distributable DMG.
#
# Usage:
#   Tools/build_dmg.sh                    # default: Release build, DMG to dist/
#   Tools/build_dmg.sh --notarize         # also submit to Apple notary service
#   Tools/build_dmg.sh --keep-dirty       # skip xcodebuild clean
#
# Notarization requires:
#   - A "Developer ID Application" cert in the keychain
#   - notarytool credentials saved as a keychain profile named NOTARY_PROFILE
#     (default: "notary-newkit"). Set up once with:
#         xcrun notarytool store-credentials notary-newkit \
#             --key <AuthKey_XXX.p8> --key-id XXX --issuer <UUID>
#     Override the profile name via env: NOTARY_PROFILE=other-name
#
# Output: dist/NewKit-<version>.dmg

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

NOTARIZE=0
DO_CLEAN=1
for arg in "$@"; do
    case "$arg" in
        --notarize)    NOTARIZE=1 ;;
        --keep-dirty)  DO_CLEAN=0 ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

command -v xcodegen   >/dev/null || { echo "missing xcodegen (brew install xcodegen)";   exit 1; }
command -v create-dmg >/dev/null || { echo "missing create-dmg (brew install create-dmg)"; exit 1; }

DERIVED="$ROOT/dist/build"
RELEASE_DIR="$DERIVED/Build/Products/Release"
APP="$RELEASE_DIR/NewKit.app"
STAGING="$ROOT/dist/staging"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Release"
BUILD_ACTION=(build)
[[ $DO_CLEAN -eq 1 ]] && BUILD_ACTION=(clean build)
xcodebuild \
    -project NewKit.xcodeproj \
    -scheme NewKit \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    "${BUILD_ACTION[@]}" \
    | tail -20
[[ -d "$APP" ]] || { echo "build did not produce $APP" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$ROOT/dist/NewKit-${VERSION}.dmg"
echo "==> Version: $VERSION"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

if [[ $NOTARIZE -eq 1 ]]; then
    PROFILE="${NOTARY_PROFILE:-notary-newkit}"
    echo "==> Notarizing app (profile: $PROFILE)"
    ZIP="$ROOT/dist/NewKit-${VERSION}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    rm -f "$ZIP"

    echo "==> Stapling ticket onto app"
    xcrun stapler staple "$APP"
fi

echo "==> Staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"

echo "==> Building DMG"
rm -f "$DMG"
create-dmg \
    --volname "NewKit ${VERSION}" \
    --window-size 540 360 \
    --icon-size 96 \
    --icon "NewKit.app" 140 170 \
    --app-drop-link 400 170 \
    --no-internet-enable \
    "$DMG" "$STAGING/" \
    | tail -5

# Also notarize + staple the DMG itself, so users don't see Gatekeeper warnings
# at mount time (the .app inside is already notarized separately above).
if [[ $NOTARIZE -eq 1 ]]; then
    PROFILE="${NOTARY_PROFILE:-notary-newkit}"
    echo "==> Notarizing DMG (profile: $PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    echo "==> Stapling ticket onto DMG"
    xcrun stapler staple "$DMG"
fi

ls -lh "$DMG"
echo
echo "Done: $DMG"
if [[ $NOTARIZE -eq 0 ]]; then
    cat <<EOF

Note: this DMG is NOT notarized. Other Macs will see Gatekeeper warnings.
Workarounds for end users:
  - Right-click NewKit.app -> Open -> Open
  - Or: sudo xattr -rd com.apple.quarantine /Applications/NewKit.app

To produce a distribution-ready DMG, run with --notarize after switching
project.yml CODE_SIGN_IDENTITY to a "Developer ID Application" cert.
EOF
fi
