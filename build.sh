#!/bin/bash
# Builds VoiceMac.app — a menu-bar app bundle around the SwiftPM executable.
#
# A real .app bundle (not a bare binary) is required because macOS TCC only
# grants Microphone / Accessibility to a signed bundle with a stable bundle id.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/VoiceMac.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/VoiceMac"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. TCC keys permissions off (bundle id + code signature), so a
# rebuild changes the signature and macOS may re-prompt for Microphone and
# Accessibility. To avoid re-granting on every build, create a self-signed
# code-signing certificate in Keychain Access and set SIGN_ID to its name.
SIGN_ID="${SIGN_ID:--}"
echo "==> codesign (identity: $SIGN_ID)"
codesign --force --deep --sign "$SIGN_ID" "$APP" 2>&1 | sed 's/^/    /'

echo ""
echo "Built $APP"
echo "Run with:  open $APP"
echo "Logs:      $APP/Contents/MacOS/VoiceMac   (run directly to see stderr)"
