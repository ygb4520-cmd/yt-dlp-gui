import Foundation

// Music search without any account or key: Apple's free catalog (songs, albums, artists) and Deezer's (playlists).
// Search results become lines like "itunes:album:123 # The Beatles - Abbey Road" in the link box; when you press
// Download, each line is turned into its songs and goes through the same YouTube Music -> lyric -> video search as Spotify.

struct SearchHit: Identifiable, Equatable {
    let id: String          // e.g. "itunes:album:1441164426"
    let title: String
    let subtitle: String
    let detail: String
    /// The line that is added to the link box (the part after "#" is only a label for you).
    var line: String { "\(id) # \(subtitle.isEmpty ? title : subtitle + " - " + title)" }
}

struct CatalogRef: Equatable { let source: String; let kind: String; let id: String }

func parseCatalogLine(_ s: String) -> CatalogRef? {
    let pattern = #"^(itunes|deezer):(song|album|playlist):(\d+)(?:\s+#.*)?$"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 4,
          let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s), let c = Range(m.range(at: 3), in: s) else { return nil }
    return CatalogRef(source: s[a].lowercased(), kind: s[b].lowercased(), id: String(s[c]))
}

/// Apple Music links (music.apple.com/us/album/name/123?i=456, /album/name/123, /song/name/456) are looked up in Apple's catalog.
func parseAppleMusicLink(_ s: String) -> CatalogRef? {
    let pattern = #"^https?://(?:embed\.)?(?:classical\.)?music\.apple\.com/(?:[a-z]{2}(?:-[a-z]{2})?/)?(album|song)/(?:[^/?#]*/)?(\d+)(?:[/?#](.*))?$"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else { return nil }
    let kind = s[a].lowercased()
    if kind == "album", let r = Range(m.range(at: 3), in: s) {
        let query = String(s[r]).components(separatedBy: "#")[0].trimmingCharacters(in: CharacterSet(charactersIn: "?"))
        if let part = query.components(separatedBy: "&").first(where: { $0.hasPrefix("i=") }) {
            let id = String(part.dropFirst(2))
            if !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) { return CatalogRef(source: "itunes", kind: "song", id: id) }
        }
    }
    return CatalogRef(source: "itunes", kind: kind, id: String(s[b]))
}

func isAppleMusicAddress(_ s: String) -> Bool {
    s.range(of: #"^https?://(?:embed\.)?(?:classical\.)?music\.apple\.com/"#, options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: - polite, retrying requests (Apple's free API allows roughly 20 requests a minute)
final class Throttle {
    private let lock = NSLock()
    private var last = Date.distantPast
    func wait(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let gap = Date().timeIntervalSince(last)
        if gap < interval { Thread.sleep(forTimeInterval: interval - gap) }
        last = Date()
    }
}
let itunesThrottle = Throttle()
let deezerThrottle = Throttle()

func fetchJSON(_ url: String, throttle: Throttle, interval: TimeInterval) -> [String: Any]? {
    for attempt in 0..<2 {
        throttle.wait(attempt == 0 ? interval : 2.5)
        if let d = httpGetData(url), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
    }
    return nil
}

func itunesJSON(_ url: String) -> [String: Any]? { fetchJSON(url, throttle: itunesThrottle, interval: 0.6) }
func deezerJSON(_ url: String) -> [String: Any]? { fetchJSON(url, throttle: deezerThrottle, interval: 0.25) }

// MARK: - turning the services' answers into our own types (pure functions, tested offline)
func bigArt(_ url: String?) -> String {
    (url ?? "").replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
}

func yearOf(_ iso: Any?) -> String {
    guard let s = iso as? String, s.count >= 4 else { return "" }
    return String(s.prefix(4))
}

func itunesTrack(_ r: [String: Any]) -> Track? {
    guard let name = r["trackName"] as? String, !name.isEmpty else { return nil }
    return Track(title: name, artist: (r["artistName"] as? String) ?? "", durationMs: (r["trackTimeMillis"] as? Int) ?? 0,
                 album: (r["collectionName"] as? String) ?? "", year: yearOf(r["releaseDate"]),
                 artURL: bigArt(r["artworkUrl100"] as? String), number: (r["trackNumber"] as? Int) ?? 0,
                 total: (r["trackCount"] as? Int) ?? 0, spotifyID: "")
}

func itunesSongHits(_ json: [String: Any]) -> [SearchHit] {
    ((json["results"] as? [[String: Any]]) ?? []).compactMap { r in
        guard (r["kind"] as? String) == "song", let id = r["trackId"] as? Int, let t = itunesTrack(r) else { return nil }
        var detail = [t.album, t.year].filter { !$0.isEmpty }.joined(separator: " · ")
        if t.durationMs > 0 { detail += (detail.isEmpty ? "" : " · ") + String(format: "%d:%02d", t.durationMs / 60000, (t.durationMs / 1000) % 60) }
        return SearchHit(id: "itunes:song:\(id)", title: t.title, subtitle: t.artist, detail: detail)
    }
}

func itunesAlbumHits(_ json: [String: Any]) -> [SearchHit] {
    ((json["results"] as? [[String: Any]]) ?? []).compactMap { r in
        guard let id = r["collectionId"] as? Int, let name = r["collectionName"] as? String, (r["trackCount"] as? Int ?? 0) > 0 else { return nil }
        let n = (r["trackCount"] as? Int) ?? 0
        return SearchHit(id: "itunes:album:\(id)", title: name, subtitle: (r["artistName"] as? String) ?? "",
                         detail: [yearOf(r["releaseDate"]), "\(n) song\(n == 1 ? "" : "s")"].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// Apple returns loose matches (a search for one choir also lists unrelated stars); keep only artists whose name
/// has every searched word in it, unless that would leave nothing.
func relevantArtists(_ hits: [SearchHit], query: String) -> [SearchHit] {
    func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    let q = words(query)
    guard !q.isEmpty else { return hits }
    let matches = hits.filter { h in
        let name = words(h.title)
        return q.allSatisfy { w in name.contains { $0.hasPrefix(w) } }
    }
    return matches.isEmpty ? hits : matches
}

func itunesArtistHits(_ json: [String: Any]) -> [SearchHit] {
    ((json["results"] as? [[String: Any]]) ?? []).compactMap { r in
        guard let id = r["artistId"] as? Int, let name = r["artistName"] as? String else { return nil }
        return SearchHit(id: "itunes:artist:\(id)", title: name, subtitle: "", detail: (r["primaryGenreName"] as? String) ?? "")
    }
}

func deezerPlaylistHits(_ json: [String: Any]) -> [SearchHit] {
    ((json["data"] as? [[String: Any]]) ?? []).compactMap { r in
        guard let id = r["id"] as? Int, let title = r["title"] as? String else { return nil }
        let n = (r["nb_tracks"] as? Int) ?? 0
        let by = ((r["user"] as? [String: Any])?["name"] as? String) ?? ""
        return SearchHit(id: "deezer:playlist:\(id)", title: title, subtitle: by, detail: "\(n) song\(n == 1 ? "" : "s")")
    }
}

/// "Abbey Road (Deluxe Edition)", "Abbey Road - Remastered" and "Abbey Road" are one album for our purposes.
func foldedAlbumName(_ s: String) -> String {
    var t = s.lowercased()
    t = t.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\s+-\s+(single|ep)$"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\b(deluxe|remastered|remaster|expanded|edition|version|bonus|anniversary|explicit)\b"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespaces)
}

/// An artist's albums: duplicate editions folded into one (the one with the most songs is kept), newest first.
func foldedAlbumHits(_ json: [String: Any]) -> [SearchHit] {
    let rows = ((json["results"] as? [[String: Any]]) ?? []).filter { ($0["wrapperType"] as? String) == "collection" && ($0["collectionId"] as? Int) != nil && (($0["trackCount"] as? Int) ?? 0) > 0 }
    var best: [String: [String: Any]] = [:]
    var order: [String] = []
    for r in rows {
        let key = foldedAlbumName((r["collectionName"] as? String) ?? "")
        if let cur = best[key] {
            if ((r["trackCount"] as? Int) ?? 0) > ((cur["trackCount"] as? Int) ?? 0) { best[key] = r }
        } else { best[key] = r; order.append(key) }
    }
    let kept = order.compactMap { best[$0] }.sorted { (($0["releaseDate"] as? String) ?? "") > (($1["releaseDate"] as? String) ?? "") }
    return itunesAlbumHits(["results": kept])
}

func deezerTrack(_ r: [String: Any]) -> Track? {
    guard let title = r["title"] as? String, !title.isEmpty else { return nil }
    let album = r["album"] as? [String: Any]
    let art = (album?["cover_xl"] as? String) ?? (album?["cover_big"] as? String) ?? ""
    return Track(title: title, artist: ((r["artist"] as? [String: Any])?["name"] as? String) ?? "",
                 durationMs: ((r["duration"] as? Int) ?? 0) * 1000, album: (album?["title"] as? String) ?? "", artURL: art)
}

// MARK: - network: search and look up (call from a background thread)
private func enc(_ s: String) -> String { percentEncodeQuery(s) }

func searchCatalog(kind: String, query: String) -> (hits: [SearchHit], error: String) {
    let q = enc(query)
    switch kind {
    case "song":
        guard let j = itunesJSON("https://itunes.apple.com/search?term=\(q)&entity=song&limit=30") else { return ([], "Apple's catalog did not answer. Try again in a moment.") }
        return (itunesSongHits(j), "")
    case "album":
        guard let j = itunesJSON("https://itunes.apple.com/search?term=\(q)&entity=album&limit=30") else { return ([], "Apple's catalog did not answer. Try again in a moment.") }
        return (itunesAlbumHits(j), "")
    case "artist":
        guard let j = itunesJSON("https://itunes.apple.com/search?term=\(q)&entity=musicArtist&limit=15") else { return ([], "Apple's catalog did not answer. Try again in a moment.") }
        return (relevantArtists(itunesArtistHits(j), query: query), "")
    default:
        guard let j = deezerJSON("https://api.deezer.com/search/playlist?q=\(q)&limit=30") else { return ([], "Deezer did not answer. Try again in a moment.") }
        return (deezerPlaylistHits(j), "")
    }
}

func artistAlbums(artistID: String) -> (hits: [SearchHit], error: String) {
    guard let j = itunesJSON("https://itunes.apple.com/lookup?id=\(artistID)&entity=album&limit=200") else { return ([], "Apple's catalog did not answer. Try again in a moment.") }
    let hits = foldedAlbumHits(j)
    return (hits, hits.isEmpty ? "No albums found for this artist." : "")
}

/// Turns "itunes:album:123" (and friends) into a list of songs with their tags.
func fetchCatalog(_ ref: CatalogRef) -> (SpotifyList?, String) {
    switch (ref.source, ref.kind) {
    case ("itunes", "song"):
        guard let j = itunesJSON("https://itunes.apple.com/lookup?id=\(ref.id)"),
              let r = (j["results"] as? [[String: Any]])?.first, let t = itunesTrack(r) else { return (nil, "Apple's catalog does not have that song") }
        return (SpotifyList(name: t.title, isCollection: false, tracks: [t]), "")
    case ("itunes", "album"):
        guard let j = itunesJSON("https://itunes.apple.com/lookup?id=\(ref.id)&entity=song&limit=200"),
              let rows = j["results"] as? [[String: Any]] else { return (nil, "Apple's catalog did not answer") }
        let name = (rows.first(where: { ($0["wrapperType"] as? String) == "collection" })?["collectionName"] as? String) ?? "Album"
        let songs = rows.filter { ($0["kind"] as? String) == "song" }
            .sorted { (($0["discNumber"] as? Int) ?? 1, ($0["trackNumber"] as? Int) ?? 0) < (($1["discNumber"] as? Int) ?? 1, ($1["trackNumber"] as? Int) ?? 0) }
            .compactMap(itunesTrack)
        return songs.isEmpty ? (nil, "That album has no songs in Apple's catalog") : (SpotifyList(name: name, isCollection: true, tracks: songs), "")
    case ("deezer", "playlist"):
        guard let meta = deezerJSON("https://api.deezer.com/playlist/\(ref.id)"), let title = meta["title"] as? String else { return (nil, "Deezer did not answer") }
        var tracks: [Track] = []
        var next: String? = "https://api.deezer.com/playlist/\(ref.id)/tracks?limit=100"
        while let url = next, tracks.count < maxTracks {
            guard let page = deezerJSON(url) else { break }
            tracks += ((page["data"] as? [[String: Any]]) ?? []).compactMap(deezerTrack)
            next = page["next"] as? String
        }
        return tracks.isEmpty ? (nil, "That playlist has no songs (it may be private)") : (SpotifyList(name: title, isCollection: true, tracks: tracks), "")
    default:
        return (nil, "Unsupported item")
    }
}

// MARK: - tests
func catalogSelfTest(_ eq: (Any, Any, String) -> Void) {
    eq(parseCatalogLine("itunes:album:1441164426 # The Beatles - Abbey Road") == CatalogRef(source: "itunes", kind: "album", id: "1441164426"), true, "album line")
    eq(parseCatalogLine("ITUNES:SONG:55") == CatalogRef(source: "itunes", kind: "song", id: "55"), true, "song line, any case")
    eq(parseCatalogLine("deezer:playlist:9 #x") == CatalogRef(source: "deezer", kind: "playlist", id: "9"), true, "playlist line")
    eq(parseCatalogLine("itunes:artist:1") == nil, true, "artist lines are only for browsing")
    eq(parseCatalogLine("https://itunes:album:1") == nil, true, "must start the line")
    eq(parseCatalogLine("itunes:album:12x") == nil, true, "id is digits only")
    eq(parseAppleMusicLink("https://music.apple.com/us/album/abbey-road/1441164426") == CatalogRef(source: "itunes", kind: "album", id: "1441164426"), true, "apple album link")
    eq(parseAppleMusicLink("https://music.apple.com/us/album/something/1441164426?i=1441164430&l=en") == CatalogRef(source: "itunes", kind: "song", id: "1441164430"), true, "apple album link with ?i= is a song")
    eq(parseAppleMusicLink("https://music.apple.com/il/song/something/1441164430") == CatalogRef(source: "itunes", kind: "song", id: "1441164430"), true, "apple song link")
    eq(parseAppleMusicLink("https://music.apple.com/us/album/1441164426") == CatalogRef(source: "itunes", kind: "album", id: "1441164426"), true, "apple album link without a name")
    eq(parseAppleMusicLink("https://music.apple.com/us/playlist/x/pl.abc") == nil, true, "apple playlist not supported")
    eq(parseAppleMusicLink("https://evil.com/?u=https://music.apple.com/us/album/x/1") == nil, true, "must start with apple")
    eq(isAppleMusicAddress("https://music.apple.com/us/artist/x/1"), true, "apple address")
    eq(isAppleMusicAddress("https://notmusic.apple.com.evil.com/x"), false, "lookalike host")
    eq(bigArt("https://x/100x100bb.jpg"), "https://x/1000x1000bb.jpg", "1000 px art")
    let song: [String: Any] = ["kind": "song", "trackId": 11, "trackName": "Chazak!", "artistName": "Avraham Fried", "collectionName": "Chazak!", "trackNumber": 1, "trackCount": 11,
                               "trackTimeMillis": 269000, "releaseDate": "2010-01-01T08:00:00Z", "artworkUrl100": "https://x/100x100bb.jpg"]
    let t = itunesTrack(song)
    eq(t?.title ?? "", "Chazak!", "song title"); eq(t?.number ?? 0, 1, "track number"); eq(t?.total ?? 0, 11, "track total"); eq(t?.year ?? "", "2010", "year")
    eq(t?.artURL ?? "", "https://x/1000x1000bb.jpg", "song art"); eq(t?.durationMs ?? 0, 269000, "song length")
    let sh = itunesSongHits(["results": [song, ["kind": "music-video", "trackId": 12, "trackName": "v"], ["wrapperType": "artist"]]])
    eq(sh.count, 1, "only songs in song hits"); eq(sh.first?.id ?? "", "itunes:song:11", "song hit id")
    eq(sh.first?.line ?? "", "itunes:song:11 # Avraham Fried - Chazak!", "song line label")
    eq(sh.first?.detail ?? "", "Chazak! · 2010 · 4:29", "song detail")
    let albums: [String: Any] = ["results": [
        ["wrapperType": "artist", "artistName": "Queen"],
        ["wrapperType": "collection", "collectionId": 1, "collectionName": "Abbey Road", "artistName": "The Beatles", "trackCount": 17, "releaseDate": "1969-09-26T07:00:00Z"],
        ["wrapperType": "collection", "collectionId": 2, "collectionName": "Abbey Road (Deluxe Edition)", "artistName": "The Beatles", "trackCount": 40, "releaseDate": "2019-09-27T07:00:00Z"],
        ["wrapperType": "collection", "collectionId": 3, "collectionName": "Abbey Road - Remastered", "artistName": "The Beatles", "trackCount": 17, "releaseDate": "2009-09-09T07:00:00Z"],
        ["wrapperType": "collection", "collectionId": 4, "collectionName": "Help! - EP", "artistName": "The Beatles", "trackCount": 4, "releaseDate": "1965-08-06T07:00:00Z"],
        ["wrapperType": "collection", "collectionId": 5, "collectionName": "Empty", "artistName": "The Beatles", "trackCount": 0, "releaseDate": "1970-01-01T07:00:00Z"]]]
    let folded = foldedAlbumHits(albums)
    eq(folded.map { $0.id }, ["itunes:album:2", "itunes:album:4"], "editions folded (largest kept), empty dropped, newest first")
    eq(foldedAlbumName("Abbey Road (Remastered 2009)"), "abbey road", "fold brackets")
    eq(foldedAlbumName("Abbey Road - Single"), "abbey road", "fold single suffix")
    eq(foldedAlbumName("Hineni"), "hineni", "plain name")
    eq(foldedAlbumName("שיר"), "שיר", "Hebrew letters are kept")
    let pl = deezerPlaylistHits(["data": [["id": 5, "title": "Jewish Wedding Dance", "nb_tracks": 5, "user": ["name": "DJ"]], ["title": "no id"]]])
    eq(pl.count, 1, "playlist hits"); eq(pl.first?.line ?? "", "deezer:playlist:5 # DJ - Jewish Wedding Dance", "playlist line"); eq(pl.first?.detail ?? "", "5 songs", "playlist detail")
    let dt = deezerTrack(["title": "Dance", "duration": 200, "artist": ["name": "Band"], "album": ["title": "LP", "cover_xl": "https://x/xl.jpg"]])
    eq(dt?.durationMs ?? 0, 200000, "deezer seconds to ms"); eq(dt?.album ?? "", "LP", "deezer album"); eq(dt?.artURL ?? "", "https://x/xl.jpg", "deezer art")
    eq(itunesArtistHits(["results": [["artistId": 9, "artistName": "ישי ריבו", "primaryGenreName": "Pop"]]]).first?.id ?? "", "itunes:artist:9", "artist hit")
    let artists = [SearchHit(id: "a", title: "The Miami Boys Choir", subtitle: "", detail: ""), SearchHit(id: "b", title: "Al Green", subtitle: "", detail: ""),
                   SearchHit(id: "c", title: "Yerachmiel Begun & the Miami Boys Choir", subtitle: "", detail: "")]
    eq(relevantArtists(artists, query: "miami boys choir").map { $0.id }, ["a", "c"], "unrelated artists dropped")
    eq(relevantArtists(artists, query: "Beyoncé").map { $0.id }, ["a", "b", "c"], "nothing matches: keep all rather than show nothing")
    eq(relevantArtists([SearchHit(id: "x", title: "Beyoncé", subtitle: "", detail: "")], query: "beyonce").map { $0.id }, ["x"], "accents ignored")
    eq(relevantArtists([SearchHit(id: "h", title: "ישי ריבו", subtitle: "", detail: "")], query: "ישי").map { $0.id }, ["h"], "Hebrew words match")
    eq(relevantArtists(artists, query: "mia").map { $0.id }, ["a", "c"], "partial words match word starts")
}
