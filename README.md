# yt-dlp GUI

A small window for downloading video or audio with [yt-dlp](https://github.com/yt-dlp/yt-dlp). One Python file, standard library only, works on Mac and Windows.

- Paste links (one per line), choose Video or Audio only, pick a save folder, press Download.
- Audio is saved as it comes from the site (usually .m4a), no conversion.
- Video: with ffmpeg it joins the best picture and sound; without ffmpeg it saves a single file with sound if the site offers one (on YouTube that is up to 360p).
- YouTube links work best with Node.js installed.

## Run
- **Mac:** double-click `yt-dlp GUI.app` (it uses the built-in /usr/bin/python3). Or `python3 yt_gui.py`.
- **Windows:** install Python from python.org, then double-click `Start yt-dlp GUI.bat`.

The app looks for `yt-dlp` on your PATH, next to the app, in `~/Applications`, and in Downloads. Get it from the yt-dlp releases page.

Self-test (no window): `python3 yt_gui.py --selftest`
