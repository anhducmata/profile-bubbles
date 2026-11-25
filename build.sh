#!/bin/zsh
# Build Profile Bubbles.app into ./build (needs Xcode Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Profile Bubbles.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 app/Sources/main.swift -o "$APP/Contents/MacOS/ProfileBubbles" -framework Cocoa -framework Carbon -framework ServiceManagement
cp app/Info.plist "$APP/Contents/Info.plist"
# A stable identity keeps privacy grants (Full Disk Access, Accessibility) across rebuilds.
# Ad-hoc signing changes the code hash on every build, and macOS then forgets the grants.
IDENTITY="${SIGN_IDENTITY:-Local App Signing}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No \"$IDENTITY\" certificate in the keychain, signing ad-hoc (grants will not survive rebuilds)."
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
