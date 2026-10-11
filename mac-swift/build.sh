#!/bin/bash
# Builds "yt-dlp GUI.app" from the Swift sources (needs Xcode or the Command Line Tools). Opens no window.
set -e
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < ../VERSION)"
APP="build.noindex/yt-dlp GUI.app"
rm -rf build.noindex && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -framework AVFoundation -framework CoreMedia Sources/*.swift -o build.noindex/yt-dlp-gui-arm64
swiftc -swift-version 5 -O -target x86_64-apple-macos13.0 -framework AVFoundation -framework CoreMedia Sources/*.swift -o build.noindex/yt-dlp-gui-x86_64
lipo -create build.noindex/yt-dlp-gui-arm64 build.noindex/yt-dlp-gui-x86_64 -output "$APP/Contents/MacOS/yt-dlp-gui"
rm build.noindex/yt-dlp-gui-arm64 build.noindex/yt-dlp-gui-x86_64
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # made by make_icon.swift + iconutil
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>yt-dlp GUI</string>
  <key>CFBundleDisplayName</key><string>yt-dlp GUI</string>
  <key>CFBundleIdentifier</key><string>com.ygb4520.ytdlpgui</string>
  <key>CFBundleExecutable</key><string>yt-dlp-gui</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
# A second copy for testing: same program, but its own identity, so its saved settings and window position never touch
# the real app (and it is not meant to be installed). Used with the debug driver.
DEBUG_APP="build.noindex/yt-dlp GUI Debug.app"
ditto "$APP" "$DEBUG_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.ygb4520.ytdlpgui.debug" -c "Set :CFBundleName yt-dlp GUI Debug" -c "Set :CFBundleDisplayName yt-dlp GUI Debug" "$DEBUG_APP/Contents/Info.plist"
codesign --force --deep --sign - "$DEBUG_APP"
echo "Built: $PWD/$APP  (version $VERSION)"
echo "Test copy: $PWD/$DEBUG_APP"
