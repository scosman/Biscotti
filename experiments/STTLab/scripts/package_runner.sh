#!/usr/bin/env bash
# Build STTLabRunner.app, ad-hoc sign it, and zip it for transfer to the runner Mac.
# Run from the repo root or from experiments/STTLab.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building STTLabRunner (release)..."
swift build -c release --product STTLabRunner

BIN="$(swift build -c release --product STTLabRunner --show-bin-path)/STTLabRunner"
APP="build/STTLabRunner.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/STTLabRunner"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>net.scosman.sttlab.runner</string>
    <key>CFBundleName</key>
    <string>STTLabRunner</string>
    <key>CFBundleExecutable</key>
    <string>STTLabRunner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Transcribes test meetings on this Mac for an experiment.</string>
</dict>
</plist>
PLIST

echo "Signing..."
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP"

echo "Creating zip..."
mkdir -p build
ditto -c -k --keepParent "$APP" build/STTLabRunner.zip

echo "Built $APP and build/STTLabRunner.zip"
