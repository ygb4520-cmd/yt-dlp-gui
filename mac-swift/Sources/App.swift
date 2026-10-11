import SwiftUI
import AppKit

struct Row: Identifiable {
    let id: Int
    let url: String
    var status: String
    var file: String?
}

final class Model: ObservableObject {
    @Published var rows: [Row] = []
    @Published var log = ""
    @Published var progress = 0.0
    @Published var speedText = ""
    @Published var busy = false
    @Published var ytdlp: String?
    @Published var hasJS = false
    @Published var hasFFmpeg = false

    private let runner = Runner()
    private var js: (String, String)?
    private var ffmpeg: String?

    init() { refreshTools(saved: UserDefaults.standard.string(forKey: "ytdlpPath")) }

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

    func addLog(_ text: String) { log += (log.isEmpty ? "" : "\n") + text }

    func cancel() { runner.cancel() }

    func start(links: String, audio: Bool, height: String, folder: String, playlist: Bool) {
        guard !busy else { return }
        guard let base = ytdlp else { addLog("yt-dlp was not found."); return }
        let raw = links.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var urls = raw.filter(validURL)
        let bad = raw.filter { !validURL($0) }
        if !bad.isEmpty { addLog("Skipped (not an http/https link): " + bad.map { String($0.prefix(60)) }.joined(separator: ", ")) }
        if urls.isEmpty { addLog("Paste at least one link that starts with http:// or https://"); return }
        if urls.count > maxLinks { addLog("Only the first \(maxLinks) links are used."); urls = Array(urls.prefix(maxLinks)) }
        let chosen = folder.trimmingCharacters(in: .whitespaces).isEmpty ? defaultFolder : folder
        let dir = (chosen as NSString).expandingTildeInPath
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            addLog("Cannot use that folder: \(error.localizedDescription)"); return
        }
        rows = urls.enumerated().map { Row(id: $0.offset, url: $0.element, status: "Waiting", file: nil) }
        progress = 0
        speedText = ""
        busy = true
        let (js, ffmpeg) = (self.js, self.ffmpeg)
        DispatchQueue.global(qos: .userInitiated).async { [runner] in
            runner.run(base: base, urls: urls, audio: audio, height: height, folder: dir, playlist: playlist, js: js, ffmpeg: ffmpeg) { ev in
                DispatchQueue.main.async { self.apply(ev) }
            }
        }
    }

    private func apply(_ ev: JobEvent) {
        switch ev {
        case .row(let i, let status):
            if rows.indices.contains(i) { rows[i].status = status }
            if status == "Done" { progress = 100; speedText = "" }
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

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var links = ""
    @AppStorage("mode") private var mode = "video"
    @AppStorage("height") private var height = "720"
    @AppStorage("playlist") private var playlist = false
    @AppStorage("folder") private var folder = defaultFolder

    private var audio: Bool { mode == "audio" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Links (one per line)").font(.headline)
            HStack(alignment: .top) {
                TextEditor(text: $links)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        links += (links.isEmpty || links.hasSuffix("\n") ? "" : "\n") + s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                    }
                }
            }

            HStack(spacing: 14) {
                Picker("", selection: $mode) {
                    Text("Video").tag("video")
                    Text("Audio only").tag("audio")
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
                Picker("Max height", selection: $height) {
                    ForEach(heights, id: \.self) { Text($0 == "best" ? "Best" : "\($0)p").tag($0) }
                }
                .frame(width: 170)
                .disabled(audio)
                Toggle("Whole playlist", isOn: $playlist)
                Spacer()
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
                Button("Download") { model.start(links: links, audio: audio, height: height, folder: folder, playlist: playlist) }
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
                    Text(row.status).foregroundColor(color(for: row.status)).frame(width: 110, alignment: .leading)
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
        .frame(minWidth: 640, minHeight: 600)
    }

    private var hint: String {
        if audio { return "Audio is saved as it comes from the site (usually .m4a), with no conversion." }
        if model.hasFFmpeg { return "ffmpeg found: video is joined from the best picture and sound, up to the height you choose." }
        return "No ffmpeg: video is saved as one file with sound in it, the best single-file quality the site offers (on YouTube that is up to 360p)."
    }

    private func color(for status: String) -> Color {
        switch status {
        case "Done": return .green
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

struct YtDlpGUIApp: App {
    var body: some Scene {
        WindowGroup("yt-dlp GUI") { ContentView() }
            .defaultSize(width: 680, height: 640)
    }
}
