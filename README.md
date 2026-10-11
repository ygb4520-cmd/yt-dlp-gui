# yt-dlp GUI

A small window for downloading video or audio with [yt-dlp](https://github.com/yt-dlp/yt-dlp). Paste links (one per line), choose Video or Audio only, pick a save folder, press Download.

- Audio is saved as it comes from the site (usually .m4a), no conversion.
- Video: with ffmpeg it joins the best picture and sound; without ffmpeg it saves a single file with sound if the site offers one (on YouTube that is up to 360p).
- YouTube links work best with Node.js installed.
- **Spotify (Mac app and Windows version):** paste a Spotify song, album or playlist link and the app reads the song list from Spotify's public page (no account or key), then looks for each song on YouTube **in this order: YouTube Music, then a lyric video, then an official video, then any music video, and last the plain top result**. Each place only counts if its length is within a few seconds of Spotify's (10 s for YouTube Music and lyric videos, 20 s for videos), and covers, live versions, remixes, karaoke and so on are skipped unless the song's own name says so. The row shows where the song came from, for example "Done (lyric video)". For albums and playlists a window lists the songs so you can **tick the ones you want** (turn that off with "Choose Spotify songs"). Spotify songs are always saved as audio (m4a) with the **title, artist, album artist, track number, year and cover art written into the file**, with no ffmpeg needed (the Mac app uses macOS's audio framework; the Windows version writes the MP4 tags itself). Albums and playlists go into a folder named after them. Album links also give the album name and track numbers; single songs and playlist songs get cover art, artist, title and year but no album name (Spotify's page does not give it). Artist, podcast and short links are not supported, and Spotify's public page may list only the first ~100 songs of a very large playlist.
- A YouTube download that fails with "403 Forbidden" is retried automatically (up to 3 tries), because YouTube does that at random.
- **Audio quality:** choose "m4a" (plays everywhere) or "best available" (often .webm/opus). YouTube audio tops out around 128-160 kbps either way. **Video quality:** choose a max height; without ffmpeg, YouTube video is limited to the single-file formats it still offers (up to 360p).

## Mac (native Swift app)
`cd mac-swift && ./build.sh` builds a universal `build/yt-dlp GUI.app` (needs Xcode or the Command Line Tools). Copy it to Applications. No Python needed. It looks for `yt-dlp` on your PATH, in `~/Applications`, and in Downloads; or press "Locate yt-dlp...".
Logic check without a window: `"build/yt-dlp GUI.app/Contents/MacOS/yt-dlp-gui" --selftest`

## Windows (Python)
Install Python from python.org, then double-click `Start yt-dlp GUI.bat` (runs `yt_gui.py`, standard library only). The same file runs on a Mac with python.org Python, but Apple's built-in Python has an old Tk that shows a blank window on recent macOS, which is why the Mac app is native.
Logic check: `python3 yt_gui.py --selftest`
