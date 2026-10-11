import AppKit
import Foundation

let debugDriverRequested = ProcessInfo.processInfo.environment["YTGUI_DEBUG_DRIVER"] != nil

/// Opt-in debug mode (modelled on the Catan and Hebrew PDF Extractor drivers). Launch with `YTGUI_DEBUG_DRIVER` set
/// to a scratch directory and the real app runs, but:
///  - it has no Dock icon and its windows are fully transparent and click-through, so nothing shows on screen;
///  - about twice a second it writes `status.txt` (settings, link box, download rows, search and song-picker state,
///    log) and `snapshot.png` (the window's own rendering; `snapshot_sheet.png` too while a Search or song-picker
///    sheet is open) into that directory;
///  - it runs commands written one per line to `command.txt` (consumed and deleted when applied).
/// Everything is in-process, so no Accessibility or Screen Recording permission is needed. Inert unless the
/// environment variable is set. Launch:  open -g -n --env YTGUI_DEBUG_DRIVER=<dir> "yt-dlp GUI.app"
@MainActor
final class DebugDriver {
    static var shared: DebugDriver?

    static func startIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["YTGUI_DEBUG_DRIVER"] else { return }
        shared = DebugDriver(directory: URL(fileURLWithPath: dir))
    }

    private let directory: URL
    private let model = appModel
    private var log: [String] = []
    private var busy = false
    private var lastSnapshot = Date.distantPast
    private var timer: Timer?

    private init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        note("driver started")
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func note(_ message: String) {
        log.append("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(message)")
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { !$0.isSheet && $0.contentView != nil && $0.title == "yt-dlp GUI" } ?? NSApp.windows.first { !$0.isSheet && $0.contentView != nil }
    }

    private func tick() {
        for w in NSApp.windows { w.alphaValue = 0; w.ignoresMouseEvents = true }   // invisible and click-through
        let commandURL = directory.appendingPathComponent("command.txt")
        if !busy, let text = try? String(contentsOf: commandURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: commandURL)
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            busy = true
            Task {
                for line in lines { await run(line) }
                busy = false
                writeStatus()
                writeSnapshots()
            }
        }
        writeStatus()
        if Date().timeIntervalSince(lastSnapshot) > 2 { writeSnapshots() }
    }

    // MARK: Commands

    private func waitFor(_ seconds: Double, _ what: String, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 250_000_000) }
        if !condition() { note("timed out waiting for \(what)") }
    }

    private func onOff(_ s: String) -> Bool { ["on", "true", "yes", "1"].contains(s.lowercased()) }

    private func indexes(_ s: String, count: Int) -> [Int] {
        if s.lowercased() == "all" { return Array(0..<count) }
        if s.lowercased() == "none" { return [] }
        return s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 >= 0 && $0 < count }
    }

    private func run(_ line: String) async {
        note("> \(line)")
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts[0].lowercased()
        let arg = parts.count > 1 ? parts[1] : ""
        let d = UserDefaults.standard
        switch name {
        case "links": model.links = arg.replacingOccurrences(of: "\\n", with: "\n")
        case "addlink": model.addLinks([arg])
        case "mode": d.set(arg == "audio" ? "audio" : "video", forKey: "mode")
        case "height": d.set(arg, forKey: "height")
        case "audioformat": d.set(arg == "best" ? "best" : "m4a", forKey: "audioFormat")
        case "playlist": d.set(onOff(arg), forKey: "playlist")
        case "asksongs": d.set(onOff(arg), forKey: "askSongs")
        case "folder": d.set((arg as NSString).expandingTildeInPath, forKey: "folder")
        case "download": model.startDownload()
        case "cancel": model.cancel()
        case "waitidle": await waitFor(300, "downloads to finish") { !model.busy }
        case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 1) * 1_000_000_000))
        // the Search window
        case "search": model.showSearch = true
        case "closesearch": model.showSearch = false
        case "searchkind": model.search.changeKind(arg)
        case "query": model.search.query = arg
        case "dosearch": model.search.search()
        case "waitsearch": await waitFor(60, "search") { !model.search.busy }
        case "searchselect": model.search.selection = Set(indexes(arg, count: model.search.hits.count).map { model.search.hits[$0].id })
        case "showalbums":
            if let i = Int(arg), model.search.hits.indices.contains(i) { model.search.showAlbums(model.search.hits[i]) } else { note("showalbums: bad index") }
        case "searchback": model.search.back()
        case "searchadd": model.search.addSelected()
        // the song picker (appears when an album or playlist is about to be downloaded)
        case "waitpicker": await waitFor(60, "song picker") { model.picker != nil }
        case "pickall": model.picker?.selected = Set((model.picker?.tracks.indices).map { Array($0) } ?? [])
        case "picknone": model.picker?.selected = []
        case "picktoggle":
            if let p = model.picker, let i = Int(arg), p.tracks.indices.contains(i) {
                if p.selected.contains(i) { p.selected.remove(i) } else { p.selected.insert(i) }
            } else { note("picktoggle: no picker or bad index") }
        case "pickok": model.finishPicker(Array(model.picker?.selected ?? []))
        case "pickskip": model.finishPicker([])
        // the window
        case "size":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let w = mainWindow() { w.setContentSize(NSSize(width: n[0], height: n[1])); note("window content size set to \(Int(n[0]))x\(Int(n[1]))") }
        // updates (set YTGUI_UPDATE_FEED to a test release file; "installupdate <folder>" puts the new app in that folder instead of replacing this one)
        case "checkupdates": model.checkUpdates(manual: true)
        case "waitupdatecheck": await waitFor(60, "update check") { !model.updateBusy }
        case "installupdate":
            var finished = false
            model.installUpdate(testDestination: URL(fileURLWithPath: (arg as NSString).expandingTildeInPath).appendingPathComponent("yt-dlp GUI.app")) { finished = true }
            await waitFor(120, "update install") { finished }
        case "shot": break
        case "quit": NSApp.terminate(nil)
        default: note("unknown command: \(name)")
        }
        try? await Task.sleep(nanoseconds: 300_000_000)   // let SwiftUI redraw before the next command
    }

    // MARK: Output

    private func writeStatus() {
        let d = UserDefaults.standard
        var out = "busy: \(busy) | downloading: \(model.busy)\n"
        if let w = mainWindow() { out += "window: content \(Int(w.contentView?.bounds.width ?? 0))x\(Int(w.contentView?.bounds.height ?? 0)) (min \(Int(w.contentMinSize.width))x\(Int(w.contentMinSize.height)))\n" }
        out += "settings: mode=\(d.string(forKey: "mode") ?? "video") height=\(d.string(forKey: "height") ?? "720") audioFormat=\(d.string(forKey: "audioFormat") ?? "m4a") "
        out += "playlist=\((d.object(forKey: "playlist") as? Bool) ?? false) askSongs=\((d.object(forKey: "askSongs") as? Bool) ?? true) folder=\(d.string(forKey: "folder") ?? defaultFolder)\n"
        out += "version: \(appVersion) | update available: \(model.update?.version ?? "none") | update message: \(model.updateMessage)\(model.updateProgress.map { " | downloading \(Int($0 * 100))%" } ?? "")\n"
        out += "tools: yt-dlp=\(model.ytdlp ?? "NOT FOUND") node/deno=\(model.hasJS) ffmpeg=\(model.hasFFmpeg)\n"
        out += "links box (\(model.links.split(whereSeparator: \.isNewline).count) lines):\n" + model.links + "\n"
        out += "rows (\(model.rows.count)), progress \(Int(model.progress))%, \(model.speedText):\n"
        for (i, r) in model.rows.enumerated() { out += "  [\(i)] \(r.status) | \(r.url)\(r.file.map { " -> \($0)" } ?? "")\n" }
        if let p = model.picker {
            out += "song picker OPEN: \(p.name) - \(p.selected.count) of \(p.tracks.count) selected\n"
            for (i, t) in p.tracks.prefix(12).enumerated() { out += "  [\(i)]\(p.selected.contains(i) ? "*" : " ") \(trackLabel(t))\n" }
        } else { out += "song picker: closed\n" }
        let s = model.search
        out += "search window: \(model.showSearch ? "OPEN" : "closed") | kind=\(s.kind) query=\"\(s.query)\" busy=\(s.busy) artist=\(s.artist?.title ?? "-") message=\"\(s.message)\"\n"
        out += "  hits (\(s.hits.count)), selected \(s.selection.count):\n"
        for (i, h) in s.hits.prefix(15).enumerated() { out += "  [\(i)]\(s.selection.contains(h.id) ? "*" : " ") \(h.id) | \(h.title) | \(h.subtitle) | \(h.detail)\n" }
        out += "--- app log ---\n" + model.log.split(separator: "\n").suffix(12).joined(separator: "\n") + "\n"
        out += "--- driver log ---\n" + log.suffix(15).joined(separator: "\n") + "\n"
        out += "--- commands: links <text, \\n for new line> | addlink <line> | mode video|audio | height best|1080|720|480|360 | audioformat m4a|best | playlist on|off | asksongs on|off | folder <path> | download | cancel | waitidle | wait <s> | search | closesearch | searchkind song|album|artist|playlist | query <text> | dosearch | waitsearch | searchselect <i,j|all|none> | showalbums <i> | searchback | searchadd | waitpicker | pickall | picknone | picktoggle <i> | pickok | pickskip | checkupdates | waitupdatecheck | installupdate <test folder> | size <w> <h> | shot | quit ---\n"
        try? out.write(to: directory.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }

    private func png(of view: NSView?) -> Data? {
        guard let view = view, view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func writeSnapshots() {
        lastSnapshot = Date()
        guard let main = mainWindow() else { return }
        if let data = png(of: main.contentView) { try? data.write(to: directory.appendingPathComponent("snapshot.png"), options: .atomic) }
        let sheetURL = directory.appendingPathComponent("snapshot_sheet.png")
        if let sheet = main.attachedSheet, let data = png(of: sheet.contentView) {
            try? data.write(to: sheetURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: sheetURL)
        }
    }
}
