#!/bin/bash
# Builds Antsly.app into ./dist (or $DIST_DIR). Usage: scripts/bundle.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="${DIST_DIR:-dist}/Antsly.app"
REPO="${APP_REPO:-kalahroudi/antsly}"
BRANCH="${APP_BRANCH:-main}"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$COMMIT" != "unknown" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi

swift build -c release --product Antsly
swift build -c release --product antsly-mcp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Antsly" "$APP/Contents/MacOS/Antsly"
cp "$BIN/antsly-mcp" "$APP/Contents/MacOS/antsly-mcp"

# App icon, drawn by the app itself so no image tools are needed.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN/Antsly" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Antsly</string>
  <key>CFBundleDisplayName</key><string>Antsly</string>
  <key>CFBundleIdentifier</key><string>com.kalahroudi.antsly</string>
  <key>CFBundleExecutable</key><string>Antsly</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>AntslyCommit</key><string>$COMMIT</string>
  <key>AntslyRepo</key><string>$REPO</string>
  <key>AntslyBranch</key><string>$BRANCH</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>productivity</string>
</dict>
</plist>
PLIST

# Ad-hoc signed by default. An ad-hoc signature normally identifies a build by its code hash, so macOS treats every
# rebuild as a different app and drops privacy grants (Accessibility, Automation, Full Disk Access...). To keep a grant
# across updates, the signature carries a fixed designated requirement tied to the bundle id, not to the code hash.
# With SIGN_IDENTITY set to a "Developer ID Application: ..." identity the default requirement (team id + bundle id)
# is already stable, so it is signed for distribution with the hardened runtime and no override.
APP_ID="com.kalahroudi.antsly"
if [ "${SIGN_IDENTITY:--}" = "-" ]; then
  APP_FLAGS=(--force --sign - -r="designated => identifier \"$APP_ID\"")
  MCP_FLAGS=(--force --sign - --identifier "$APP_ID-mcp" -r="designated => identifier \"$APP_ID-mcp\"")
else
  APP_FLAGS=(--force --timestamp --options runtime --entitlements scripts/Antsly.entitlements --sign "$SIGN_IDENTITY")
  MCP_FLAGS=("${APP_FLAGS[@]}")
fi
codesign "${MCP_FLAGS[@]}" "$APP/Contents/MacOS/antsly-mcp"
codesign "${APP_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
