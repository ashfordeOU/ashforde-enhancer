#!/bin/bash
# Builds dist/Ashforde Enhancer.app (universal) and dist/AshfordeEnhancer-<version>.zip.
# Signs with SIGN_IDENTITY when set (Developer ID, hardened runtime, timestamp), ad hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${GITHUB_RUN_NUMBER:-1}"
APP="dist/Ashforde Enhancer.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AshfordeEnhancer" "$APP/Contents/MacOS/AshfordeEnhancer"
sed -e "s/<string>VERSION<\/string>/<string>$VERSION<\/string>/" -e "s/<string>BUILD<\/string>/<string>$BUILD<\/string>/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --entitlements Resources/Enhancer.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
(cd dist && ditto -c -k --keepParent "Ashforde Enhancer.app" "AshfordeEnhancer-$VERSION.zip")
echo "==> dist/AshfordeEnhancer-$VERSION.zip"
