# yt-dlp GUI

A small window for downloading video or audio with [yt-dlp](https://github.com/yt-dlp/yt-dlp). Paste links (one per line), choose Video or Audio only, pick a save folder, press Download.

- Audio is saved as it comes from the site (usually .m4a), no conversion.
- Video: with ffmpeg it joins the best picture and sound; without ffmpeg it saves a single file with sound if the site offers one (on YouTube that is up to 360p).
- YouTube links work best with Node.js installed.

## Mac (native Swift app)
`cd mac-swift && ./build.sh` builds a universal `build/yt-dlp GUI.app` (needs Xcode or the Command Line Tools). Copy it to Applications. No Python needed. It looks for `yt-dlp` on your PATH, in `~/Applications`, and in Downloads; or press "Locate yt-dlp...".
Logic check without a window: `"build/yt-dlp GUI.app/Contents/MacOS/yt-dlp-gui" --selftest`

## Windows (Python)
Install Python from python.org, then double-click `Start yt-dlp GUI.bat` (runs `yt_gui.py`, standard library only). The same file runs on a Mac with python.org Python, but Apple's built-in Python has an old Tk that shows a blank window on recent macOS, which is why the Mac app is native.
Logic check: `python3 yt_gui.py --selftest`
