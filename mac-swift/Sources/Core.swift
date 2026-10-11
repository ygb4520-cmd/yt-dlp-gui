import Foundation

// Pure logic: finding the tools, building the yt-dlp command line, reading its output. No window needed.

let heights = ["best", "1080", "720", "480", "360"]
let defaultFolder = NSHomeDirectory() + "/Downloads/yt-dlp"
let maxLinks = 20

let needsFFmpegMessage = "That site only offers the picture and the sound as separate streams, and joining them needs ffmpeg. Audio only still works without it."

func validURL(_ s: String) -> Bool {
    s.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

private func isExecutableFile(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        && FileManager.default.isExecutableFile(atPath: path)
}

private func searchPath(_ name: String) -> String? {
    let envDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for d in envDirs + ["/opt/homebrew/bin", "/usr/local/bin"] {
        let p = d + "/" + name
        if isExecutableFile(p) { return p }
    }
    return nil
}

func findYtDlp(saved: String?) -> String? {
    var cands: [String] = []
    if let s = saved, !s.isEmpty { cands.append(s) }
    if let r = Bundle.main.resourcePath { cands.append(r + "/yt-dlp") }
    if let p = searchPath("yt-dlp") { cands.append(p) }
    let home = NSHomeDirectory()
    cands += [home + "/Applications/yt-dlp", home + "/Downloads/yt-dlp_macos", home + "/Downloads/yt-dlp"]
    return cands.first(where: isExecutableFile)
}

private func versionKey(_ s: String) -> [Int] {
    s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
}

/// YouTube needs a JavaScript runtime for its player code. Returns (name, path).
func findJS() -> (String, String)? {
    for name in ["node", "deno"] {
        if let p = searchPath(name) { return (name, p) }
    }
    let nvm = NSHomeDirectory() + "/.nvm/versions/node"
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
        let sorted = versions.sorted { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
        for v in sorted.reversed() {
            let p = nvm + "/" + v + "/bin/node"
            if isExecutableFile(p) { return ("node", p) }
        }
    }
    let deno = NSHomeDirectory() + "/.deno/bin/deno"
    return isExecutableFile(deno) ? ("deno", deno) : nil
}

func findFFmpeg() -> String? {
    if let r = Bundle.main.resourcePath, isExecutableFile(r + "/ffmpeg") { return r + "/ffmpeg" }
    return searchPath("ffmpeg")
}

func formatFor(audio: Bool, height: String, ffmpeg: String?) -> String {
    if audio { return "bestaudio[ext=m4a]/bestaudio/best" }
    if ffmpeg != nil {   // picture and sound are joined by ffmpeg
        return height == "best" ? "bv*+ba/b" : "bv*[height<=\(height)]+ba/b[height<=\(height)]/b"
    }
    return height == "best" ? "b[ext=mp4]/b" : "b[height<=\(height)][ext=mp4]/b[height<=\(height)]/b"
}

private func commonArguments(audio: Bool, height: String, folder: String, playlist: Bool,
                              js: (String, String)?, ffmpeg: String?, outTemplate: String) -> [String] {
    var a = ["--newline", "--no-quiet", "--no-colors", "--windows-filenames",
             "-P", folder, "-o", outTemplate,
             "--progress-template", "download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
             "--print", "after_move:FILE|%(filepath)s",
             playlist ? "--yes-playlist" : "--no-playlist",
             "-f", formatFor(audio: audio, height: height, ffmpeg: ffmpeg)]
    if let ff = ffmpeg, !audio {
        a += ["--ffmpeg-location", ff, "--merge-output-format", "mp4"]
    } else if !audio {
        // YouTube's default clients no longer offer the older single-file formats (like 18, up to 360p); mweb still does.
        a += ["--extractor-args", "youtube:player_client=default,mweb"]
    }
    if let j = js { a += ["--js-runtimes", "\(j.0):\(j.1)"] }
    return a
}

func buildArguments(url: String, audio: Bool, height: String, folder: String, playlist: Bool,
                    js: (String, String)?, ffmpeg: String?) -> [String] {
    commonArguments(audio: audio, height: height, folder: folder, playlist: playlist, js: js, ffmpeg: ffmpeg,
                    outTemplate: "%(title).100s.%(ext)s") + ["--", url]
}

// MARK: - Spotify links (song / album / playlist): read the song list, then search YouTube for each song

struct SpotifyRef: Equatable { let kind: String; let id: String }
struct Track: Equatable { let title: String; let artist: String; let durationMs: Int }
struct SpotifyList: Equatable { let name: String; let isCollection: Bool; let tracks: [Track] }

let maxTracks = 200
let durationSlackSeconds = 10

func parseSpotifyLink(_ s: String) -> SpotifyRef? {
    let patterns = [#"^https?://open\.spotify\.com/(?:intl-[a-z-]+/)?(track|album|playlist)/([A-Za-z0-9]{22})(?:[/?#].*)?$"#,
                    #"^spotify:(track|album|playlist):([A-Za-z0-9]{22})$"#]
    for pat in patterns {
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 3,
              let k = Range(m.range(at: 1), in: s), let i = Range(m.range(at: 2), in: s) else { continue }
        return SpotifyRef(kind: s[k].lowercased(), id: String(s[i]))
    }
    return nil
}

/// Finds the JSON Spotify puts in its public embed page and returns the "entity" (the song, album or playlist).
func spotifyEntity(fromHTML html: String) -> [String: Any]? {
    guard let a = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
          let b = html.range(of: "</script>", range: a.upperBound..<html.endIndex),
          let obj = try? JSONSerialization.jsonObject(with: Data(html[a.upperBound..<b.lowerBound].utf8)) as? [String: Any],
          let props = obj["props"] as? [String: Any], let page = props["pageProps"] as? [String: Any],
          let state = page["state"] as? [String: Any], let data = state["data"] as? [String: Any],
          let entity = data["entity"] as? [String: Any] else { return nil }
    return entity
}

func parseSpotifyEntity(_ e: [String: Any]) -> SpotifyList? {
    let name = (e["name"] as? String) ?? (e["title"] as? String) ?? "Spotify"
    if (e["type"] as? String) == "track" {
        let artists = ((e["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        guard !name.isEmpty else { return nil }
        return SpotifyList(name: name, isCollection: false, tracks: [Track(title: name, artist: artists, durationMs: (e["duration"] as? Int) ?? 0)])
    }
    guard let list = e["trackList"] as? [[String: Any]], !list.isEmpty else { return nil }
    let tracks = list.compactMap { t -> Track? in
        guard let title = t["title"] as? String, !title.isEmpty else { return nil }
        return Track(title: title, artist: (t["subtitle"] as? String) ?? "", durationMs: (t["duration"] as? Int) ?? 0)
    }
    return tracks.isEmpty ? nil : SpotifyList(name: name, isCollection: true, tracks: tracks)
}

func isSpotifyAddress(_ s: String) -> Bool {
    s.range(of: #"^(https?://([a-z0-9-]+\.)*(spotify\.com|spotify\.link)/|spotify:)"#, options: [.regularExpression, .caseInsensitive]) != nil
}

func safeFileName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    let cleaned = s.components(separatedBy: bad).joined(separator: " ")
        .split(whereSeparator: { $0 == " " }).joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return String((cleaned.isEmpty ? "Spotify" : cleaned).prefix(120))
}

func trackLabel(_ t: Track) -> String { t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)" }

/// One song: search YouTube. `strict` keeps only results whose length is within a few seconds of Spotify's.
func buildTrackArguments(track: Track, strict: Bool, audio: Bool, height: String, folder: String,
                         js: (String, String)?, ffmpeg: String?) -> [String] {
    let out = safeFileName(trackLabel(track)).replacingOccurrences(of: "%", with: "%%") + ".%(ext)s"
    var a = commonArguments(audio: audio, height: height, folder: folder, playlist: false, js: js, ffmpeg: ffmpeg, outTemplate: out)
    let query = trackLabel(track).replacingOccurrences(of: " - ", with: " ")
    a += ["--max-downloads", "1"]
    if strict && track.durationMs > 0 {
        let d = Int((Double(track.durationMs) / 1000).rounded())
        a += ["--match-filter", "duration>=\(d - durationSlackSeconds) & duration<=\(d + durationSlackSeconds)"]
        return a + ["--", "ytsearch5:\(query)"]
    }
    return a + ["--", "ytsearch1:\(query)"]
}

enum OutLine: Equatable {
    case progress(Double, String, String)
    case file(String)
    case error(String)
}

func parseLine(_ raw: String) -> OutLine? {
    let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("PROG|") {
        let parts = line.components(separatedBy: "|")
        guard parts.count >= 4 else { return nil }
        let pct = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "% ")).trimmingCharacters(in: .whitespaces)
        guard let value = Double(pct) else { return nil }
        return .progress(value, parts[2].trimmingCharacters(in: .whitespaces), parts[3].trimmingCharacters(in: .whitespaces))
    }
    if line.hasPrefix("FILE|") { return .file(String(line.dropFirst(5))) }
    if line.hasPrefix("ERROR") {
        let one = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return .error(String(one.prefix(300)))
    }
    return nil
}

// MARK: - self-test (run: yt-dlp-gui --selftest). Opens no window.
func selfTest() -> Bool {
    var passed = 0, failed = 0
    func eq<T: Equatable>(_ a: T, _ b: T, _ m: String) {
        if a == b { passed += 1 } else { failed += 1; print("FAIL \(m): \(a) != \(b)") }
    }
    eq(validURL("https://a.com/x"), true, "https ok")
    eq(validURL("http://a.com"), true, "http ok")
    eq(validURL("--exec=rm"), false, "option-like rejected")
    eq(validURL("file:///etc/passwd"), false, "file scheme rejected")
    eq(validURL("https://a.com/x y"), false, "space rejected")
    eq(formatFor(audio: true, height: "720", ffmpeg: nil), "bestaudio[ext=m4a]/bestaudio/best", "audio fmt")
    eq(formatFor(audio: false, height: "best", ffmpeg: nil), "b[ext=mp4]/b", "video best")
    eq(formatFor(audio: false, height: "480", ffmpeg: nil), "b[height<=480][ext=mp4]/b[height<=480]/b", "video 480")
    eq(formatFor(audio: false, height: "720", ffmpeg: "/f"), "bv*[height<=720]+ba/b[height<=720]/b", "merge fmt")
    eq(formatFor(audio: false, height: "best", ffmpeg: "/f"), "bv*+ba/b", "merge best")
    let c = buildArguments(url: "https://a.com/v", audio: false, height: "720", folder: "/tmp/x", playlist: false, js: ("node", "/n"), ffmpeg: nil)
    eq(Array(c.suffix(2)), ["--", "https://a.com/v"], "url after --")
    eq(c.contains("--no-playlist"), true, "no playlist default")
    eq(c[c.firstIndex(of: "--js-runtimes")! + 1], "node:/n", "js runtime")
    eq(c[c.firstIndex(of: "--extractor-args")! + 1], "youtube:player_client=default,mweb", "mweb without ffmpeg")
    eq(c.contains("-x"), false, "never converts audio")
    let cf = buildArguments(url: "https://a", audio: false, height: "720", folder: "/t", playlist: false, js: nil, ffmpeg: "/f/ffmpeg")
    eq(cf[cf.firstIndex(of: "--ffmpeg-location")! + 1], "/f/ffmpeg", "ffmpeg location")
    eq(cf.contains("--extractor-args"), false, "no client override with ffmpeg")
    eq(cf.contains("--js-runtimes"), false, "no js flag when none")
    let ca = buildArguments(url: "https://a", audio: true, height: "720", folder: "/t", playlist: true, js: nil, ffmpeg: "/f")
    eq(ca.contains("--yes-playlist"), true, "playlist flag")
    eq(ca.contains("--ffmpeg-location") || ca.contains("--extractor-args"), false, "audio adds nothing")
    eq(parseLine("PROG| 45.3%|1.2MiB/s|00:03"), .progress(45.3, "1.2MiB/s", "00:03"), "progress")
    eq(parseLine("PROG|  N/A|Unknown|Unknown"), nil, "unknown progress ignored")
    eq(parseLine("FILE|/tmp/a b.mp4"), .file("/tmp/a b.mp4"), "file")
    eq(parseLine("ERROR: [youtube] x: Sign in to confirm"), .error("ERROR: [youtube] x: Sign in to confirm"), "error")
    eq(parseLine("[download] Destination: x"), nil, "other lines ignored")
    eq(parseLine("\u{1B}[0;32mPROG| 10.0%|1MiB/s|00:01\u{1B}[0m"), .progress(10.0, "1MiB/s", "00:01"), "ansi stripped")
    eq(versionKey("v24.19.0").lexicographicallyPrecedes(versionKey("v9.0.0")), false, "numeric version order")
    // Spotify
    eq(parseSpotifyLink("https://open.spotify.com/track/3z8h0TU7ReDPLIbEnYhWZb?si=abc"), SpotifyRef(kind: "track", id: "3z8h0TU7ReDPLIbEnYhWZb"), "track link")
    eq(parseSpotifyLink("https://open.spotify.com/intl-fr/album/0ETFjACtuP2ADo6LFhL6HN"), SpotifyRef(kind: "album", id: "0ETFjACtuP2ADo6LFhL6HN"), "intl album link")
    eq(parseSpotifyLink("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M/"), SpotifyRef(kind: "playlist", id: "37i9dQZF1DXcBWIGoYBM5M"), "playlist link")
    eq(parseSpotifyLink("spotify:track:3z8h0TU7ReDPLIbEnYhWZb"), SpotifyRef(kind: "track", id: "3z8h0TU7ReDPLIbEnYhWZb"), "uri")
    eq(parseSpotifyLink("https://open.spotify.com/artist/3z8h0TU7ReDPLIbEnYhWZb"), nil, "artist not supported")
    eq(parseSpotifyLink("https://evil.com/?u=https://open.spotify.com/track/3z8h0TU7ReDPLIbEnYhWZb"), nil, "must start with spotify")
    let page = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{\"pageProps\":{\"state\":{\"data\":{\"entity\":{\"type\":\"album\",\"name\":\"Abbey Road\",\"trackList\":[{\"title\":\"Come Together\",\"subtitle\":\"The Beatles\",\"duration\":259946},{\"title\":\"Something\",\"subtitle\":\"The Beatles\",\"duration\":182000},{\"subtitle\":\"no title\"}]}}}}}}</script></html>"
    let al = spotifyEntity(fromHTML: page).flatMap(parseSpotifyEntity)
    eq(al?.name, "Abbey Road", "album name")
    eq(al?.isCollection, true, "album is collection")
    eq(al?.tracks, [Track(title: "Come Together", artist: "The Beatles", durationMs: 259946), Track(title: "Something", artist: "The Beatles", durationMs: 182000)], "album tracks")
    let one = parseSpotifyEntity(["type": "track", "name": "Bohemian Rhapsody", "duration": 354947, "artists": [["name": "Queen"], ["name": "Other"]]])
    eq(one?.tracks, [Track(title: "Bohemian Rhapsody", artist: "Queen, Other", durationMs: 354947)], "single track")
    eq(one?.isCollection, false, "single is not a collection")
    eq(spotifyEntity(fromHTML: "<html>nothing</html>") == nil, true, "no data page")
    eq(parseSpotifyEntity(["type": "playlist", "name": "x", "trackList": []]) == nil, true, "empty list is nil")
    eq(safeFileName("AC/DC: Back In Black?"), "AC DC Back In Black", "safe name")
    eq(safeFileName("..."), "Spotify", "empty safe name")
    eq(isSpotifyAddress("https://open.spotify.com/artist/abc"), true, "spotify address")
    eq(isSpotifyAddress("https://spotify.link/xyz"), true, "spotify short link")
    eq(isSpotifyAddress("https://notspotify.com/x"), false, "lookalike host")
    eq(isSpotifyAddress("https://youtube.com/watch?v=1"), false, "youtube is not spotify")
    let t = Track(title: "100% Pure", artist: "Queen", durationMs: 200000)
    let strict = buildTrackArguments(track: t, strict: true, audio: true, height: "720", folder: "/t", js: nil, ffmpeg: nil)
    eq(Array(strict.suffix(2)), ["--", "ytsearch5:Queen 100% Pure"], "strict search query")
    eq(strict[strict.firstIndex(of: "--match-filter")! + 1], "duration>=190 & duration<=210", "duration window")
    eq(strict[strict.firstIndex(of: "--max-downloads")! + 1], "1", "max one download")
    eq(strict[strict.firstIndex(of: "-o")! + 1], "Queen - 100%% Pure.%(ext)s", "percent escaped in file name")
    let loose = buildTrackArguments(track: t, strict: false, audio: true, height: "720", folder: "/t", js: nil, ffmpeg: nil)
    eq(Array(loose.suffix(2)), ["--", "ytsearch1:Queen 100% Pure"], "loose search")
    eq(loose.contains("--match-filter"), false, "no filter when loose")
    let nodur = buildTrackArguments(track: Track(title: "X", artist: "", durationMs: 0), strict: true, audio: true, height: "720", folder: "/t", js: nil, ffmpeg: nil)
    eq(Array(nodur.suffix(2)), ["--", "ytsearch1:X"], "no length known uses plain search")
    print("\(passed) passed, \(failed) failed")
    return failed == 0
}
