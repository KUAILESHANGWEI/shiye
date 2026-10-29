#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="拾页预览.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -module-cache-path /private/tmp/shiyu-module-cache -target arm64-apple-macosx13.0 Sources/WebApp.swift Sources/BackupStore.swift -o "$APP/Contents/MacOS/Shiyu"
cp web/index.html "$APP/Contents/Resources/index.html"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>拾页预览</string><key>CFBundleIdentifier</key><string>local.shiyu.preview</string><key>CFBundleExecutable</key><string>Shiyu</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.2</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
