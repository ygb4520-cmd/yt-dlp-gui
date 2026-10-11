import Foundation

enum JobEvent {
    case row(Int, String)
    case progress(Int, Double, String, String)
    case file(Int, String)
    case log(String)
    case finished
}

/// Runs the links one after another (call from a background thread) and reports through `report`.
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

    func run(base: String, urls: [String], audio: Bool, height: String, folder: String, playlist: Bool,
             js: (String, String)?, ffmpeg: String?, report: @escaping (JobEvent) -> Void) {
        lock.lock(); cancelledFlag = false; lock.unlock()
        for (i, url) in urls.enumerated() {
            if cancelled { report(.row(i, "Cancelled")); continue }
            report(.row(i, "Starting..."))
            let (code, err) = runOne(base: base, i: i, args: buildArguments(url: url, audio: audio, height: height, folder: folder,
                                                                           playlist: playlist, js: js, ffmpeg: ffmpeg), report: report)
            if cancelled {
                report(.row(i, "Cancelled"))
            } else if code == 0 {
                report(.row(i, "Done"))
            } else {
                report(.row(i, "Failed"))
                var why = err.isEmpty ? "yt-dlp stopped with an error (exit code \(code))" : err
                if !audio && ffmpeg == nil && why.contains("Requested format is not available") { why = needsFFmpegMessage }
                report(.log("\(url)\n  \(why)"))
            }
        }
        report(.finished)
    }

    private func runOne(base: String, i: Int, args: [String], report: @escaping (JobEvent) -> Void) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: base)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        lock.lock(); process = p; lock.unlock()
        var lastError = ""
        do { try p.run() } catch { return (1, "could not run yt-dlp: \(error.localizedDescription)") }
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        func handleLine(_ data: Data) {
            guard let ev = parseLine(String(decoding: data, as: UTF8.self)) else { return }
            switch ev {
            case .progress(let pct, let speed, let eta): report(.progress(i, pct, speed, eta))
            case .file(let path): report(.file(i, path))
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
        return (p.terminationStatus, lastError)
    }
}
