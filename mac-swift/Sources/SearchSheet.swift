import SwiftUI

/// The "Search..." window: look up songs, albums, artists or playlists and add them to the link box.
struct SearchSheet: View {
    let add: ([String]) -> Void
    let close: () -> Void

    @State private var kind = "song"
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var selection = Set<String>()
    @State private var busy = false
    @State private var message = ""
    @State private var artist: SearchHit?        // set while looking at one artist's albums
    @State private var artistResults: [SearchHit] = []

    private let kinds = [("song", "Songs"), ("album", "Albums"), ("artist", "Artists"), ("playlist", "Playlists")]
    private var browsingArtists: Bool { kind == "artist" && artist == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(artist.map { "Albums by \($0.title)" } ?? "Search music").font(.headline)

            if artist == nil {
                HStack {
                    Picker("", selection: $kind) {
                        ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: kind) { _ in hits = []; selection = []; message = "" }
                }
                HStack {
                    TextField(placeholder, text: $query).onSubmit { search() }
                    Button("Search") { search() }.disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("< Back to artists") { backToArtists() }
            }

            if busy { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.footnote).foregroundColor(.secondary) }

            if artist != nil {
                HStack {
                    Button("Select all") { selection = Set(hits.map { $0.id }) }
                    Button("Select none") { selection = [] }
                    Spacer()
                    Text("\(selection.count) of \(hits.count) selected").foregroundColor(.secondary)
                }
            }

            List(hits) { hit in
                HStack {
                    if browsingArtists {
                        Text(hit.title).lineLimit(1)
                        Spacer()
                        Text(hit.detail).foregroundColor(.secondary)
                        Button("Show albums") { showAlbums(hit) }
                    } else {
                        Toggle(isOn: Binding(get: { selection.contains(hit.id) }, set: { on in
                            if on { selection.insert(hit.id) } else { selection.remove(hit.id) }
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
                Text(kind == "playlist" ? "Playlists come from Deezer; songs, albums and artists from Apple's catalog." : "Songs, albums and artists come from Apple's free catalog.")
                    .font(.footnote).foregroundColor(.secondary)
                Spacer()
                Button("Close") { close() }
                if !browsingArtists {
                    Button("Add \(selection.count)") { addSelected() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 600, height: 540)
    }

    private var placeholder: String {
        switch kind {
        case "song": return "Song name (add the artist for better results)"
        case "album": return "Album name"
        case "artist": return "Artist name"
        default: return "Playlist name"
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true; message = ""; hits = []; selection = []
        let k = kind
        DispatchQueue.global(qos: .userInitiated).async {
            let r = searchCatalog(kind: k, query: q)
            DispatchQueue.main.async {
                busy = false
                hits = r.hits
                message = !r.error.isEmpty ? r.error : (r.hits.isEmpty ? "Nothing found. Try fewer words or another spelling." : "")
            }
        }
    }

    private func showAlbums(_ a: SearchHit) {
        busy = true; message = ""
        artistResults = hits
        let id = a.id.split(separator: ":").last.map(String.init) ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = artistAlbums(artistID: id)
            DispatchQueue.main.async {
                busy = false
                if r.hits.isEmpty { message = r.error; return }
                artist = a
                hits = r.hits
                selection = Set(r.hits.map { $0.id })   // all ticked; untick what you do not want
                message = "Duplicate editions (Deluxe, Remastered...) are folded into one."
            }
        }
    }

    private func backToArtists() {
        artist = nil; hits = artistResults; selection = []; message = ""
    }

    private func addSelected() {
        let lines = hits.filter { selection.contains($0.id) }.map { $0.line }
        add(lines)
        message = "Added \(lines.count). They are now in the link box."
        selection = []
    }
}
