import Foundation

enum JobEvent {
    case plan([String])                 // the list of rows to show (after Spotify links were expanded)
    case row(Int, String)
    case progress(Int, Double, String, String)
    case file(Int, String)
    case log(String)
    case finished
}

enum Target {
    case link(String)
    case track(Track)                   // a song from Spotify: searched on YouTube
}

struct Job {
    let label: String
    let target: Target
    let folder: String
}

/// Reads a Spotify song, album or playlist from Spotify's public embed page (no account or key needed).
func fetchSpotify(_ ref: SpotifyRef) -> (SpotifyList?, String) {
    guard let url = URL(string: "https://open.spotify.com/embed/\(ref.kind)/\(ref.id)") else { return (nil, "bad Spotify link") }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var body: Data?
    var status = 0
    var failure = ""
    URLSession.shared.dataTask(with: req) { d, r, e in
        body = d
        status = (r as? HTTPURLResponse)?.statusCode ?? 0
        if let e = e { failure = e.localizedDescription }
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + 30) == .timedOut { return (nil, "Spotify did not answer in time") }
    if !failure.isEmpty { return (nil, failure) }
    guard status == 200, let d = body, let html = String(data: d, encoding: .utf8) else { return (nil, "Spotify answered with HTTP \(status)") }
    guard let entity = spotifyEntity(fromHTML: html), let list = parseSpotifyEntity(entity) else {
        return (nil, "Spotify did not list the songs (the playlist may be private or not available in your region)")
    }
    return (list, "")
}

/// Turns the pasted lines into jobs: plain links stay as they are, Spotify links become one job per song.
func planJobs(lines: [String], baseFolder: String, log: (String) -> Void) -> [Job] {
    var jobs: [Job] = []
    var plainLinks = 0
    for line in lines {
        if let ref = parseSpotifyLink(line) {
            let (list, why) = fetchSpotify(ref)
            guard let l = list else { log("\(line)\n  \(why)"); continue }
            let folder = l.isCollection ? baseFolder + "/" + safeFileName(l.name) : baseFolder
            var tracks = l.tracks
            if tracks.count > maxTracks { log("Only the first \(maxTracks) songs of \"\(l.name)\" are used."); tracks = Array(tracks.prefix(maxTracks)) }
            log("Spotify: \"\(l.name)\" has \(l.tracks.count) song\(l.tracks.count == 1 ? "" : "s"). Searching YouTube for each one" + (l.isCollection ? ", saving into a folder named after it." : "."))
            jobs += tracks.map { Job(label: trackLabel($0), target: .track($0), folder: folder) }
        } else if isSpotifyAddress(line) {
            log("\(line)\n  Only Spotify song, album and playlist links work. Artist, podcast and short links are not supported; open the link in your browser and copy the song, album or playlist address.")
        } else if validURL(line) {
            plainLinks += 1
            if plainLinks > maxLinks { if plainLinks == maxLinks + 1 { log("Only the first \(maxLinks) plain links are used.") }; continue }
            jobs.append(Job(label: line, target: .link(line), folder: baseFolder))
        } else {
            log("Skipped (not an http/https link): \(String(line.prefix(60)))")
        }
    }
    return jobs
}

/// Runs the jobs one after another (call from a background thread) and reports through `report`.
final class Runner {
    private let lock = NSLock()
    private var process: Process?
    private var cancelledFlag = false

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        let p = process
        lock.unlock()
        if let p = p, p.isRunning { p.terminate() }
    }

    func run(base: String, jobs: [Job], audio: Bool, height: String, playlist: Bool,
             js: (String, String)?, ffmpeg: String?, report: @escaping (JobEvent) -> Void) {
        lock.lock(); cancelledFlag = false; lock.unlock()
        for (i, job) in jobs.enumerated() {
            if cancelled { report(.row(i, "Cancelled")); continue }
            report(.row(i, "Starting..."))
            try? FileManager.default.createDirectory(atPath: job.folder, withIntermediateDirectories: true)
            switch job.target {
            case .link(let url):
                let r = runOne(base: base, i: i, report: report, args: buildArguments(url: url, audio: audio, height: height, folder: job.folder,
                                                                                     playlist: playlist, js: js, ffmpeg: ffmpeg))
                if cancelled {
                    report(.row(i, "Cancelled"))
                } else if r.code == 0 {
                    report(.row(i, "Done"))
                } else {
                    report(.row(i, "Failed"))
                    var why = r.error.isEmpty ? "yt-dlp stopped with an error (exit code \(r.code))" : r.error
                    if !audio && ffmpeg == nil && why.contains("Requested format is not available") { why = needsFFmpegMessage }
                    report(.log("\(url)\n  \(why)"))
                }
            case .track(let t):
                var r = runOne(base: base, i: i, report: report, args: buildTrackArguments(track: t, strict: true, audio: audio, height: height,
                                                                                          folder: job.folder, js: js, ffmpeg: ffmpeg))
                var lengthDiffers = false
                if r.file == nil && !cancelled && t.durationMs > 0 {   // nothing within a few seconds of Spotify's length: take the top result
                    report(.row(i, "Trying top result..."))
                    r = runOne(base: base, i: i, report: report, args: buildTrackArguments(track: t, strict: false, audio: audio, height: height,
                                                                                         folder: job.folder, js: js, ffmpeg: ffmpeg))
                    lengthDiffers = r.file != nil
                }
                if cancelled {
                    report(.row(i, "Cancelled"))
                } else if r.file != nil {
                    report(.row(i, lengthDiffers ? "Done (length differs)" : "Done"))
                } else {
                    report(.row(i, "Failed"))
                    report(.log("\(job.label)\n  \(r.error.isEmpty ? "No match found on YouTube." : r.error)"))
                }
            }
        }
        report(.finished)
    }

    private func runOne(base: String, i: Int, report: @escaping (JobEvent) -> Void, args: [String]) -> (code: Int32, error: String, file: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: base)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        lock.lock(); process = p; lock.unlock()
        var lastError = ""
        var lastFile: String?
        do { try p.run() } catch { return (1, "could not run yt-dlp: \(error.localizedDescription)", nil) }
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        func handleLine(_ data: Data) {
            guard let ev = parseLine(String(decoding: data, as: UTF8.self)) else { return }
            switch ev {
            case .progress(let pct, let speed, let eta): report(.progress(i, pct, speed, eta))
            case .file(let path): lastFile = path; report(.file(i, path))
            case .error(let text): lastError = text
            }
        }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 10) {
                handleLine(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { handleLine(buffer) }
        p.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        return (p.terminationStatus, lastError, lastFile)
    }
}
