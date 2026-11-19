#!/bin/bash
# Builds AgentAwake.app (universal: Apple Silicon + Intel).
# Usage: ./build.sh [--install] [--zip]
#   --install  copy to ~/Applications and launch
#   --zip      also create build/AgentAwake.zip (for releases / Homebrew)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
APP="build/AgentAwake.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos11" Sources/*.swift \
    -o "build/obj/AgentAwake-$arch" -framework Cocoa -framework IOKit
done
lipo -create build/obj/AgentAwake-arm64 build/obj/AgentAwake-x86_64 -output "$APP/Contents/MacOS/AgentAwake"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentAwake</string>
  <key>CFBundleIdentifier</key><string>local.agentawake</string>
  <key>CFBundleExecutable</key><string>AgentAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>AgentAwake reads iTerm2 / Terminal windows to see whether your coding agents are working, asking a question or hit a usage limit, and types "continue" after a limit resets.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP ($VERSION)"

for arg in "$@"; do
  case "$arg" in
    --zip)
      (cd build && ditto -c -k --keepParent AgentAwake.app AgentAwake.zip)
      echo "Zipped build/AgentAwake.zip  sha256: $(shasum -a 256 build/AgentAwake.zip | cut -d' ' -f1)"
      ;;
    --install)
      mkdir -p ~/Applications
      pkill -x AgentAwake 2>/dev/null || true
      sleep 1
      rm -rf ~/Applications/AgentAwake.app
      cp -R "$APP" ~/Applications/
      open ~/Applications/AgentAwake.app
      echo "Installed to ~/Applications/AgentAwake.app and launched"
      ;;
  esac
done
