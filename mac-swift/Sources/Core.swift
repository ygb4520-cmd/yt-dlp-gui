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

func buildArguments(url: String, audio: Bool, height: String, folder: String, playlist: Bool,
                    js: (String, String)?, ffmpeg: String?) -> [String] {
    var a = ["--newline", "--no-quiet", "--no-colors", "--windows-filenames",
             "-P", folder, "-o", "%(title).100s.%(ext)s",
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
    return a + ["--", url]
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
    print("\(passed) passed, \(failed) failed")
    return failed == 0
}
