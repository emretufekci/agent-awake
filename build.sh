#!/bin/bash
# Builds AgentAwake.app. Usage: ./build.sh [--install] [--login]
#   --install  copy to ~/Applications and launch
#   --login    also add it to Login Items (start at login)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AgentAwake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/AgentAwake" \
  -framework Cocoa -framework IOKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentAwake</string>
  <key>CFBundleIdentifier</key><string>local.agentawake</string>
  <key>CFBundleExecutable</key><string>AgentAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      mkdir -p ~/Applications
      pkill -x AgentAwake 2>/dev/null || true
      rm -rf ~/Applications/AgentAwake.app
      cp -R "$APP" ~/Applications/
      open ~/Applications/AgentAwake.app
      echo "Installed to ~/Applications/AgentAwake.app and launched"
      ;;
    --login)
      osascript -e 'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/AgentAwake.app", hidden:true}' >/dev/null
      echo "Added to Login Items"
      ;;
  esac
done
