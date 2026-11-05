#!/bin/zsh
# Builds release binary and wraps it into SnapDesk.app (ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
A=SnapDesk.app; rm -rf $A; mkdir -p $A/Contents/MacOS
cp .build/release/SnapDesk $A/Contents/MacOS/SnapDesk
cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SnapDesk</string><key>CFBundleExecutable</key><string>SnapDesk</string>
<key>CFBundleIdentifier</key><string>com.local.snapdesk</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>LSMinimumSystemVersion</key><string>13.0</string>

<key>NSMicrophoneUsageDescription</key><string>Record microphone audio with screen recordings.</string>
<key>NSScreenCaptureUsageDescription</key><string>Capture screenshots and recordings.</string>
</dict></plist>
P
codesign --force --deep -s - $A
echo "Built $A"
