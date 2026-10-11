import SwiftUI

/// State of the "Search..." window (kept in an object so the debug driver can read and drive it as well).
final class SearchModel: ObservableObject {
    @Published var kind = "song"
    @Published var query = ""
    @Published var hits: [SearchHit] = []
    @Published var selection = Set<String>()
    @Published var busy = false
    @Published var message = ""
    @Published var artist: SearchHit?            // set while looking at one artist's albums
    private var artistResults: [SearchHit] = []
    var addLines: ([String]) -> Void = { _ in }

    var browsingArtists: Bool { kind == "artist" && artist == nil }

    func changeKind(_ k: String) {
        kind = k; hits = []; selection = []; message = ""; artist = nil
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true; message = ""; hits = []; selection = []; artist = nil
        let k = kind
        DispatchQueue.global(qos: .userInitiated).async {
            let r = searchCatalog(kind: k, query: q)
            DispatchQueue.main.async {
                self.busy = false
                self.hits = r.hits
                self.message = !r.error.isEmpty ? r.error : (r.hits.isEmpty ? "Nothing found. Try fewer words or another spelling." : "")
            }
        }
    }

    func showAlbums(_ a: SearchHit) {
        guard !busy else { return }
        busy = true; message = ""
        artistResults = hits
        let id = a.id.split(separator: ":").last.map(String.init) ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = artistAlbums(artistID: id)
            DispatchQueue.main.async {
                self.busy = false
                if r.hits.isEmpty { self.message = r.error; return }
                self.artist = a
                self.hits = r.hits
                self.selection = Set(r.hits.map { $0.id })   // all ticked; untick what you do not want
                self.message = "Duplicate editions (Deluxe, Remastered...) are folded into one."
            }
        }
    }

    func back() {
        artist = nil; hits = artistResults; selection = []; message = ""
    }

    func addSelected() {
        let lines = hits.filter { selection.contains($0.id) }.map { $0.line }
        guard !lines.isEmpty else { return }
        addLines(lines)
        message = "Added \(lines.count). They are now in the link box."
        selection = []
    }
}

/// The "Search..." window: look up songs, albums, artists or playlists and add them to the link box.
struct SearchSheet: View {
    @ObservedObject var m: SearchModel
    let close: () -> Void

    private let kinds = [("song", "Songs"), ("album", "Albums"), ("artist", "Artists"), ("playlist", "Playlists")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.artist.map { "Albums by \($0.title)" } ?? "Search music").font(.headline)

            if m.artist == nil {
                Picker("", selection: Binding(get: { m.kind }, set: { m.changeKind($0) })) {
                    ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    TextField(placeholder, text: $m.query).onSubmit { m.search() }
                    Button("Search") { m.search() }.disabled(m.busy || m.query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("< Back to artists") { m.back() }
            }

            if m.busy { ProgressView().controlSize(.small) }
            if !m.message.isEmpty { Text(m.message).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }

            if m.artist != nil {
                HStack {
                    Button("Select all") { m.selection = Set(m.hits.map { $0.id }) }
                    Button("Select none") { m.selection = [] }
                    Spacer()
                    Text("\(m.selection.count) of \(m.hits.count) selected").foregroundColor(.secondary)
                }
            }

            List(m.hits) { hit in
                HStack {
                    if m.browsingArtists {
                        Text(hit.title).lineLimit(1)
                        Spacer()
                        Text(hit.detail).foregroundColor(.secondary)
                        Button("Show albums") { m.showAlbums(hit) }
                    } else {
                        Toggle(isOn: Binding(get: { m.selection.contains(hit.id) }, set: { on in
                            if on { m.selection.insert(hit.id) } else { m.selection.remove(hit.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title).lineLimit(1).truncationMode(.tail)
                                Text([hit.subtitle, hit.detail].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                    .font(.footnote).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Text(m.kind == "playlist" ? "Playlists come from Deezer; songs, albums and artists from Apple's free catalog." : "Songs, albums and artists come from Apple's free catalog.")
                    .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Close") { close() }
                if !m.browsingArtists {
                    Button("Add \(m.selection.count)") { m.addSelected() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(m.selection.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 600, height: 540)
    }

    private var placeholder: String {
        switch m.kind {
        case "song": return "Song name (add the artist for better results)"
        case "album": return "Album name"
        case "artist": return "Artist name"
        default: return "Playlist name"
        }
    }
}
