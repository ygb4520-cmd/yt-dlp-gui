#!/bin/bash
# Publishes a GitHub release (and its v<version> tag) for the version in VERSION. The app's built-in updater looks
# at the latest release, so every change you want people to get needs a new, higher VERSION first.
#   1. edit VERSION (for example 1.0.0 -> 1.1.0) and set the same number in yt_gui.py (VERSION = '...')
#   2. commit and push
#   3. NOTES="what changed" ./release.sh
set -e
cd "$(dirname "$0")"
V="$(tr -d '[:space:]' < VERSION)"
git diff --quiet && git diff --cached --quiet || { echo "Commit your changes first."; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ] || { echo "Push your commits first."; exit 1; }
grep -q "^VERSION = '$V'" yt_gui.py || { echo "yt_gui.py's VERSION does not match the VERSION file ($V)."; exit 1; }
git rev-parse "v$V" >/dev/null 2>&1 && { echo "v$V already exists. Raise the number in VERSION."; exit 1; }
python3 -I yt_gui.py --selftest
(cd mac-swift && ./build.sh)
"mac-swift/build.noindex/yt-dlp GUI.app/Contents/MacOS/yt-dlp-gui" --selftest
rm -rf dist && mkdir dist
ditto -c -k --keepParent "mac-swift/build.noindex/yt-dlp GUI.app" dist/yt-dlp-GUI-mac.zip
zip -q dist/yt-dlp-GUI-windows.zip yt_gui.py "Start yt-dlp GUI.bat" README.md
gh release create "v$V" dist/yt-dlp-GUI-mac.zip dist/yt-dlp-GUI-windows.zip --target main --title "yt-dlp GUI $V" --notes "${NOTES:-yt-dlp GUI $V}"
echo "Published v$V. Running copies will offer the update the next time they start (or when you press Check for updates)."
