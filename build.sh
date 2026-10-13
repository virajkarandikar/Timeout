#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=Timeout.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O Tools/makeicon.swift -o "${TMPDIR:-/tmp}/timeout-makeicon" && "${TMPDIR:-/tmp}/timeout-makeicon" $APP/Contents/Resources/AppIcon.icns
swiftc -O -swift-version 5 Sources/main.swift -o $APP/Contents/MacOS/Timeout
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Timeout</string>
<key>CFBundleIdentifier</key><string>com.timeout.app</string>
<key>CFBundleExecutable</key><string>Timeout</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - $APP
echo "Built $APP"
