#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="网站收藏.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -module-cache-path /private/tmp/shiyu-module-cache -O -target arm64-apple-macosx13.0 Sources/main.swift -o "$APP/Contents/MacOS/WebsiteShelf"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>网站收藏</string>
<key>CFBundleDisplayName</key><string>网站收藏</string>
<key>CFBundleIdentifier</key><string>local.websiteshelf.app</string>
<key>CFBundleExecutable</key><string>WebsiteShelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "已构建：$PWD/$APP"
