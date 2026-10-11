import CryptoKit
import Foundation

// Self-updater (same idea as the Hebrew Cursive Scanner's): ask GitHub for the latest release, compare it with this
// app's version, download the Mac zip, check it, and swap the app in place. No Apple developer certificate needed.

let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
let updateRepo = "ygb4520-cmd/yt-dlp-gui"
let appBundleID = "com.ygb4520.ytdlpgui"

struct UpdateInfo: Equatable {
    let version: String
    let assetName: String
    let assetURL: String
    let releaseURL: String
    let sha256: String?     // GitHub lists a checksum for each uploaded file; when present the download must match it
}

func versionParts(_ v: String) -> [Int] {
    v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
}

/// 1 if a is newer than b, -1 if older, 0 if the same.
func compareVersions(_ a: String, _ b: String) -> Int {
    let (pa, pb) = (versionParts(a), versionParts(b))
    for i in 0..<max(pa.count, pb.count) {
        let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
        if d != 0 { return d > 0 ? 1 : -1 }
    }
    return 0
}

/// Reads GitHub's "latest release" answer. Returns nil when there is nothing newer for the Mac.
func parseRelease(_ json: [String: Any], current: String) -> UpdateInfo? {
    guard let tag = json["tag_name"] as? String, compareVersions(tag, current) > 0,
          (json["draft"] as? Bool) != true, (json["prerelease"] as? Bool) != true,
          let assets = json["assets"] as? [[String: Any]],
          let asset = assets.first(where: { (($0["name"] as? String) ?? "").lowercased().hasSuffix("-mac.zip") }),
          let name = asset["name"] as? String, let url = asset["browser_download_url"] as? String else { return nil }
    // only ever download from this project's own GitHub releases
    guard url.hasPrefix("https://github.com/\(updateRepo)/releases/download/") || url.hasPrefix("file://") else { return nil }
    var digest: String?
    if let d = asset["digest"] as? String, d.hasPrefix("sha256:") { digest = String(d.dropFirst(7)).lowercased() }
    return UpdateInfo(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), assetName: name, assetURL: url,
                      releaseURL: (json["html_url"] as? String) ?? "https://github.com/\(updateRepo)/releases", sha256: digest)
}

/// Asks GitHub (or, in debug mode only, a test file named by YTGUI_UPDATE_FEED) for the latest release.
func checkForUpdate() -> (info: UpdateInfo?, error: String) {
    var feed = "https://api.github.com/repos/\(updateRepo)/releases/latest"
    if debugDriverRequested, let f = ProcessInfo.processInfo.environment["YTGUI_UPDATE_FEED"] { feed = f }
    guard let url = URL(string: feed) else { return (nil, "bad update address") }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("yt-dlp-gui/\(appVersion)", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var data: Data?
    var status = 200
    var failure = ""
    URLSession.shared.dataTask(with: req) { d, r, e in
        data = d
        if let h = r as? HTTPURLResponse { status = h.statusCode }
        if let e = e { failure = e.localizedDescription }
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + 30) == .timedOut { return (nil, "GitHub did not answer in time") }
    if !failure.isEmpty { return (nil, "could not reach GitHub (\(failure))") }
    if status == 404 { return (nil, "") }   // no release published yet
    guard status == 200, let d = data, let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (nil, "GitHub answered with HTTP \(status)") }
    return (parseRelease(json, current: appVersion), "")
}

/// Downloads a file and reports progress (0...1). Call from a background thread. Returns an error text, or "" on success.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let sem = DispatchSemaphore(value: 0)
    private var tempURL: URL?
    private var failure = ""
    private let progress: (Double) -> Void

    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func download(_ urlString: String, to dest: URL) -> String {
        guard let url = URL(string: urlString) else { return "bad download address" }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        sem.wait()
        session.finishTasksAndInvalidate()
        guard failure.isEmpty, let t = tempURL else { return failure.isEmpty ? "download failed" : failure }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: t, to: dest) } catch { return "could not save the download: \(error.localizedDescription)" }
        return ""
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("ytgui-dl-" + UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: keep)
        tempURL = keep
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 { failure = "download failed (HTTP \(http.statusCode))" }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { failure = e.localizedDescription }
        sem.signal()
    }
}

private func runTool(_ path: String, _ args: [String]) -> (ok: Bool, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (false, error.localizedDescription) }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(decoding: d, as: UTF8.self))
}

/// Downloads the update and checks it. Returns the new, ready-to-install app and the folder to delete afterwards.
func stageUpdate(_ info: UpdateInfo, progress: @escaping (Double) -> Void) -> (app: URL?, tempDir: URL?, error: String) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ytgui-update-" + UUID().uuidString)
    do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { return (nil, nil, "could not make a temporary folder") }
    func fail(_ m: String) -> (URL?, URL?, String) { try? FileManager.default.removeItem(at: tmp); return (nil, nil, m) }

    let zip = tmp.appendingPathComponent("update.zip")
    let err = FileDownloader(progress: progress).download(info.assetURL, to: zip)
    if !err.isEmpty { return fail(err) }
    if let expected = info.sha256 {
        guard let data = try? Data(contentsOf: zip) else { return fail("could not read the download") }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if actual != expected { return fail("the download does not match GitHub's checksum, so it was not installed") }
    }
    let out = tmp.appendingPathComponent("out")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let unzip = runTool("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
    if !unzip.ok { return fail("could not unpack the update") }
    guard let appName = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.first(where: { $0.hasSuffix(".app") }) else { return fail("the update did not contain an app") }
    let app = out.appendingPathComponent(appName)
    guard let plist = NSDictionary(contentsOfFile: app.appendingPathComponent("Contents/Info.plist").path),
          (plist["CFBundleIdentifier"] as? String) == appBundleID else { return fail("the update is not this app, so it was not installed") }
    guard let newVersion = plist["CFBundleShortVersionString"] as? String, compareVersions(newVersion, appVersion) > 0 else { return fail("the update is not newer than this version") }
    if !runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).ok { return fail("the update's signature is damaged, so it was not installed") }
    return (app, tmp, "")
}

/// Where the updated app should go: where this one is, or ~/Applications when that place is not writable.
func installDestination() -> URL {
    let here = Bundle.main.bundleURL
    if FileManager.default.isWritableFile(atPath: here.deletingLastPathComponent().path) { return here }
    let apps = URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true)
    try? FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    return apps.appendingPathComponent(here.lastPathComponent)
}

/// Swaps the app for the new one. A running app cannot replace itself, so a small helper script waits for this process
/// to quit, replaces the app, and opens it again. (Pass `relaunch: false` and no helper is used: the swap happens now.)
func applyUpdate(staged: URL, tempDir: URL, destination: URL, relaunch: Bool) -> String {
    if !relaunch {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: staged, to: destination)
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        } catch { return "could not install: \(error.localizedDescription)" }
    }
    let script = tempDir.appendingPathComponent("apply_update.sh")
    let body = """
    #!/bin/bash
    while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.5; done
    rm -rf "\(destination.path)"
    /usr/bin/ditto "\(staged.path)" "\(destination.path)"
    /usr/bin/open -n "\(destination.path)"
    rm -rf "\(tempDir.path)"
    """
    do { try body.write(to: script, atomically: true, encoding: .utf8) } catch { return "could not prepare the install" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path]
    p.standardOutput = nil
    p.standardError = nil
    do { try p.run() } catch { return "could not start the install: \(error.localizedDescription)" }
    return ""
}

// MARK: - tests
func updaterSelfTest(_ eq: (Any, Any, String) -> Void) {
    eq(compareVersions("1.2.0", "1.1.9"), 1, "newer minor")
    eq(compareVersions("v1.0.0", "1.0.0"), 0, "v prefix ignored")
    eq(compareVersions("1.0", "1.0.0"), 0, "missing part is zero")
    eq(compareVersions("1.9.0", "1.10.0"), -1, "numbers, not text")
    eq(compareVersions("2.0.0", "1.99.99"), 1, "major wins")
    let mac = "https://github.com/\(updateRepo)/releases/download/v1.1.0/yt-dlp-GUI-mac.zip"
    let release: [String: Any] = ["tag_name": "v1.1.0", "html_url": "https://github.com/x/y/releases/tag/v1.1.0", "assets": [
        ["name": "yt-dlp-GUI-windows.zip", "browser_download_url": "https://github.com/\(updateRepo)/releases/download/v1.1.0/yt-dlp-GUI-windows.zip"],
        ["name": "yt-dlp-GUI-mac.zip", "browser_download_url": mac, "digest": "sha256:ABCDEF12"]]]
    let info = parseRelease(release, current: "1.0.0")
    eq(info?.version ?? "", "1.1.0", "newer release found")
    eq(info?.assetURL ?? "", mac, "Mac asset chosen, Windows one ignored")
    eq(info?.sha256 ?? "", "abcdef12", "checksum read and lower-cased")
    eq(parseRelease(release, current: "1.1.0") == nil, true, "same version: nothing to do")
    eq(parseRelease(release, current: "2.0.0") == nil, true, "older release: nothing to do")
    var draft = release; draft["draft"] = true
    eq(parseRelease(draft, current: "1.0.0") == nil, true, "drafts ignored")
    var pre = release; pre["prerelease"] = true
    eq(parseRelease(pre, current: "1.0.0") == nil, true, "pre-releases ignored")
    var noMac = release; noMac["assets"] = [["name": "yt-dlp-GUI-windows.zip", "browser_download_url": "https://github.com/\(updateRepo)/releases/download/v1.1.0/yt-dlp-GUI-windows.zip"]]
    eq(parseRelease(noMac, current: "1.0.0") == nil, true, "no Mac file yet: nothing to do")
    var evil = release; evil["assets"] = [["name": "yt-dlp-GUI-mac.zip", "browser_download_url": "https://evil.example.com/yt-dlp-GUI-mac.zip"]]
    eq(parseRelease(evil, current: "1.0.0") == nil, true, "files from other sites are never downloaded")
    var other = release; other["assets"] = [["name": "yt-dlp-GUI-mac.zip", "browser_download_url": "https://github.com/someone-else/repo/releases/download/v1.1.0/yt-dlp-GUI-mac.zip"]]
    eq(parseRelease(other, current: "1.0.0") == nil, true, "files from other repositories are never downloaded")
    eq(parseRelease(["tag_name": "v9.0.0"], current: "1.0.0") == nil, true, "release without files")
}
