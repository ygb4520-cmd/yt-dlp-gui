import SwiftUI
import AppKit

struct Row: Identifiable {
    let id: Int
    let url: String
    var status: String
    var file: String?
}

/// The song list shown when an album or playlist is about to be downloaded.
final class PickerState: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let tracks: [Track]
    @Published var selected: Set<Int>
    init(name: String, tracks: [Track]) {
        self.name = name
        self.tracks = tracks
        self.selected = Set(tracks.indices)
    }
}

/// Everything the window shows lives here (not inside the views), so the debug driver can read and change it too.
final class Model: ObservableObject {
    @Published var links = ""
    @Published var showSearch = false
    @Published var picker: PickerState?
    private var pickerResult: (([Int]?) -> Void)?

    @Published var rows: [Row] = []
    @Published var log = ""
    @Published var progress = 0.0
    @Published var speedText = ""
    @Published var busy = false
    @Published var ytdlp: String?
    @Published var hasJS = false
    @Published var hasFFmpeg = false

    let search = SearchModel()
    private let runner = Runner()
    private var js: (String, String)?
    private var ffmpeg: String?

    init() {
        refreshTools(saved: UserDefaults.standard.string(forKey: "ytdlpPath"))
        search.addLines = { [unowned self] lines in self.addLinks(lines) }
    }

    func refreshTools(saved: String?) {
        ytdlp = findYtDlp(saved: saved)
        js = findJS()
        ffmpeg = findFFmpeg()
        hasJS = js != nil
        hasFFmpeg = ffmpeg != nil
        if ytdlp == nil {
            addLog("yt-dlp was not found. Press \"Locate yt-dlp...\" and pick the yt-dlp program (get it from github.com/yt-dlp/yt-dlp/releases).")
        }
    }

    func addLinks(_ lines: [String]) {
        links += (links.isEmpty || links.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n") + "\n"
    }

    /// Called from the background thread: shows the song list and waits until the user is done.
    func chooseSongs(_ list: SpotifyList) -> [Int]? {
        let sem = DispatchSemaphore(value: 0)
        var result: [Int]?
        DispatchQueue.main.async {
            self.pickerResult = { sel in result = sel; sem.signal() }
            self.picker = PickerState(name: list.name, tracks: list.tracks)
        }
        sem.wait()
        return result
    }

    func finishPicker(_ selection: [Int]?) {
        let done = pickerResult
        pickerResult = nil
        picker = nil
        done?(selection)
    }

    func addLog(_ text: String) { log += (log.isEmpty ? "" : "\n") + text }

    func cancel() { runner.cancel() }

    /// Starts downloading what is in the link box, using the saved settings.
    func startDownload() {
        let d = UserDefaults.standard
        let audio = (d.string(forKey: "mode") ?? "video") == "audio"
        let height = d.string(forKey: "height") ?? "720"
        let audioFormat = d.string(forKey: "audioFormat") ?? "m4a"
        let playlist = (d.object(forKey: "playlist") as? Bool) ?? false
        let askSongs = (d.object(forKey: "askSongs") as? Bool) ?? true
        let folder = d.string(forKey: "folder") ?? defaultFolder
        start(links: links, audio: audio, height: height, folder: folder, playlist: playlist, audioFormat: audioFormat, askSongs: askSongs)
    }

    func start(links: String, audio: Bool, height: String, folder: String, playlist: Bool, audioFormat: String, askSongs: Bool) {
        guard !busy else { return }
        guard let base = ytdlp else { addLog("yt-dlp was not found."); return }
        let lines = links.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { addLog("Paste at least one link (a website link, a Spotify link, or a search result)."); return }
        let chosen = folder.trimmingCharacters(in: .whitespaces).isEmpty ? defaultFolder : folder
        let dir = (chosen as NSString).expandingTildeInPath
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            addLog("Cannot use that folder: \(error.localizedDescription)"); return
        }
        rows = []
        progress = 0
        speedText = lines.contains(where: { parseSpotifyLink($0) != nil || parseCatalogLine($0) != nil }) ? "Looking up songs..." : ""
        busy = true
        let (js, ffmpeg) = (self.js, self.ffmpeg)
        DispatchQueue.global(qos: .userInitiated).async { [runner] in
            let jobs = planJobs(lines: lines, baseFolder: dir, log: { text in DispatchQueue.main.async { self.addLog(text) } },
                                choose: askSongs ? { self.chooseSongs($0) } : nil)
            DispatchQueue.main.async { self.apply(.plan(jobs.map { $0.label })) }
            if jobs.isEmpty { DispatchQueue.main.async { self.apply(.finished) }; return }
            runner.run(base: base, jobs: jobs, audio: audio, height: height, playlist: playlist, js: js, ffmpeg: ffmpeg, audioFormat: audioFormat) { ev in
                DispatchQueue.main.async { self.apply(ev) }
            }
        }
    }

    private func apply(_ ev: JobEvent) {
        switch ev {
        case .plan(let labels):
            rows = labels.enumerated().map { Row(id: $0.offset, url: $0.element, status: "Waiting", file: nil) }
            speedText = ""
        case .row(let i, let status):
            if rows.indices.contains(i) { rows[i].status = status }
            if status.hasPrefix("Done") { progress = 100; speedText = "" }
            if status == "Failed" || status == "Cancelled" { progress = 0; speedText = "" }
        case .progress(let i, let pct, let speed, let eta):
            progress = pct
            if rows.indices.contains(i) { rows[i].status = String(format: "%.0f%%", pct) }
            speedText = "\(speed)   ETA \(eta)"
        case .file(let i, let path):
            if rows.indices.contains(i) { rows[i].file = path }
        case .log(let text):
            addLog(text)
        case .finished:
            busy = false
        }
    }
}

let appModel = Model()

struct ContentView: View {
    @ObservedObject private var model = appModel
    @AppStorage("mode") private var mode = "video"
    @AppStorage("height") private var height = "720"
    @AppStorage("audioFormat") private var audioFormat = "m4a"
    @AppStorage("askSongs") private var askSongs = true
    @AppStorage("playlist") private var playlist = false
    @AppStorage("folder") private var folder = defaultFolder

    private var audio: Bool { mode == "audio" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Links (one per line)").font(.headline)
            Text("Website links, a Spotify song, album or playlist link, or press Search... to find music by name. Songs from Spotify and the search are always saved as audio (m4a) with title, artist, cover art and more written in.")
                .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                TextEditor(text: $model.links)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                VStack {
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            model.addLinks([s.trimmingCharacters(in: .whitespacesAndNewlines)])
                        }
                    }
                    Button("Search...") { model.showSearch = true }
                }
                .sheet(isPresented: $model.showSearch) {
                    SearchSheet(m: model.search, close: { model.showSearch = false })
                }
            }

            // two short rows, so nothing is ever wider than the window
            HStack(spacing: 14) {
                Picker("", selection: $mode) {
                    Text("Video").tag("video")
                    Text("Audio only").tag("audio")
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
                if audio {
                    Picker("Audio", selection: $audioFormat) {
                        Text("m4a (plays everywhere)").tag("m4a")
                        Text("Best available").tag("best")
                    }
                    .frame(width: 270)
                } else {
                    Picker("Max height", selection: $height) {
                        ForEach(heights, id: \.self) { Text($0 == "best" ? "Best" : "\($0)p").tag($0) }
                    }
                    .frame(width: 190)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 18) {
                Toggle("Whole playlist", isOn: $playlist)
                Toggle("Choose songs from albums and playlists", isOn: $askSongs)
                Spacer(minLength: 0)
            }

            Text(hint).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Save to")
                TextField("", text: $folder)
                Button("Choose...") { chooseFolder() }
                Button("Open folder") {
                    let f = (folder as NSString).expandingTildeInPath
                    try? FileManager.default.createDirectory(atPath: f, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: f))
                }
            }

            HStack {
                Button("Download") { model.startDownload() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy)
                Button("Cancel") { model.cancel() }.disabled(!model.busy)
                if model.ytdlp == nil { Button("Locate yt-dlp...") { locateYtDlp() } }
                ProgressView(value: model.progress, total: 100).frame(maxWidth: .infinity)
            }
            if !model.speedText.isEmpty { Text(model.speedText).font(.footnote).foregroundColor(.secondary) }

            List(model.rows) { row in
                HStack {
                    Text(row.url).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(row.status).foregroundColor(color(for: row.status)).frame(width: 150, alignment: .leading).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let f = row.file { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
                }
            }
            .frame(minHeight: 110)
            Text("Double-click a finished row to show the file.").font(.footnote).foregroundColor(.secondary)

            ScrollView {
                Text(model.log).font(.system(.footnote, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 80)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
        }
        .padding(16)
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 600)
        .sheet(item: $model.picker, onDismiss: { model.finishPicker(nil) }) { p in
            SongPicker(state: p) { model.finishPicker($0) }
        }
    }

    private var hint: String {
        if audio { return audioFormat == "best" ? "Best available: the highest-quality audio the site has, often .webm (opus). YouTube audio tops out around 130-160 kbps either way." : "m4a: plays on every device. YouTube audio tops out around 128-160 kbps, so this is close to the best there is." }
        if model.hasFFmpeg { return "ffmpeg found: video is joined from the best picture and sound, up to the height you choose." }
        return "No ffmpeg: video is saved as one file with sound in it, the best single-file quality the site offers. On YouTube that is up to 360p, so a higher max height only helps on other sites."
    }

    private func color(for status: String) -> Color {
        switch status {
        case _ where status.hasPrefix("Done"): return (status.contains("top result") || status.contains("tags")) ? .orange : .green
        case "Failed": return .red
        default: return .secondary
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }

    private func locateYtDlp() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.message = "Choose the yt-dlp program"
        if p.runModal() == .OK, let u = p.url {
            UserDefaults.standard.set(u.path, forKey: "ytdlpPath")
            model.refreshTools(saved: u.path)
        }
    }
}

struct SongPicker: View {
    @ObservedObject var state: PickerState
    let finish: ([Int]?) -> Void

    private func length(_ ms: Int) -> String { ms > 0 ? String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60) : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.name).font(.headline)
            Text("Pick the songs to download.").font(.footnote).foregroundColor(.secondary)
            HStack {
                Button("Select all") { state.selected = Set(state.tracks.indices) }
                Button("Select none") { state.selected = [] }
                Spacer()
                Text("\(state.selected.count) of \(state.tracks.count) selected").foregroundColor(.secondary)
            }
            List(Array(state.tracks.enumerated()), id: \.offset) { i, t in
                Toggle(isOn: Binding(get: { state.selected.contains(i) }, set: { on in if on { state.selected.insert(i) } else { state.selected.remove(i) } })) {
                    HStack {
                        Text("\(i + 1).").foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
                        Text(trackLabel(t)).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Text(length(t.durationMs)).foregroundColor(.secondary).monospacedDigit()
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Button("Skip this one") { finish([]) }
                Spacer()
                Button("Download \(state.selected.count) song\(state.selected.count == 1 ? "" : "s")") { finish(Array(state.selected)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if debugDriverRequested { NSApp.setActivationPolicy(.accessory) }   // no Dock icon, no menu bar takeover
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugDriver.startIfRequested()
    }
}

struct YtDlpGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("yt-dlp GUI") { ContentView() }
            .defaultSize(width: 680, height: 640)
    }
}
