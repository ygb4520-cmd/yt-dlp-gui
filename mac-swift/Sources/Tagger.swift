import AVFoundation
import CoreMedia
import Foundation

/// Plain synchronous download (call from a background thread).
func httpGetData(_ urlString: String, timeout: TimeInterval = 20) -> Data? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var out: Data?
    URLSession.shared.dataTask(with: req) { d, r, _ in
        if let http = r as? HTTPURLResponse, http.statusCode == 200 { out = d }
        sem.signal()
    }.resume()
    return sem.wait(timeout: .now() + timeout + 5) == .timedOut ? nil : out
}

/// Fills in the cover art and year from the song's own Spotify page when the list (a playlist) did not carry them.
func enrichTrack(_ t: Track) -> Track {
    guard t.artURL.isEmpty, !t.spotifyID.isEmpty else { return t }
    let (list, _) = fetchSpotify(SpotifyRef(kind: "track", id: t.spotifyID))
    guard let first = list?.tracks.first else { return t }
    var r = t
    r.artURL = first.artURL
    if r.year.isEmpty { r.year = first.year }
    return r
}

private func metadataItem(_ id: AVMetadataIdentifier, _ value: Any, _ dataType: CFString) -> AVMetadataItem {
    let it = AVMutableMetadataItem()
    it.identifier = id
    it.value = value as? (NSCopying & NSObjectProtocol)
    it.dataType = dataType as String
    return it
}

/// Writes title, artist, album, year, track number and cover art into an .m4a using macOS's own audio framework
/// (no ffmpeg needed). Returns nil on success, or a short reason.
func tagM4A(path: String, track: Track) -> String? {
    let src = URL(fileURLWithPath: path)
    let tmp = URL(fileURLWithPath: path + ".tagging.m4a")
    try? FileManager.default.removeItem(at: tmp)
    let asset = AVURLAsset(url: src)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return "could not prepare the file" }
    var items: [AVMetadataItem] = [
        metadataItem(.iTunesMetadataSongName, track.title, kCMMetadataBaseDataType_UTF8),
        metadataItem(.iTunesMetadataArtist, track.artist, kCMMetadataBaseDataType_UTF8),
    ]
    if !track.artist.isEmpty { items.append(metadataItem(.iTunesMetadataAlbumArtist, track.artist.components(separatedBy: ", ").first ?? track.artist, kCMMetadataBaseDataType_UTF8)) }
    if !track.album.isEmpty { items.append(metadataItem(.iTunesMetadataAlbum, track.album, kCMMetadataBaseDataType_UTF8)) }
    if !track.year.isEmpty { items.append(metadataItem(.iTunesMetadataReleaseDate, track.year, kCMMetadataBaseDataType_UTF8)) }
    if track.number > 0 {
        let n = UInt8(min(track.number, 255)), total = UInt8(min(track.total, 255))
        items.append(metadataItem(.iTunesMetadataTrackNumber, Data([0, 0, 0, n, 0, total, 0, 0]), kCMMetadataBaseDataType_RawData))
    }
    var artNote = ""
    if !track.artURL.isEmpty {
        if let art = httpGetData(track.artURL), art.count > 1000 {
            let isPNG = art.starts(with: [0x89, 0x50])
            items.append(metadataItem(.iTunesMetadataCoverArt, art, isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG))
        } else {
            artNote = " (cover art could not be downloaded)"
        }
    } else {
        artNote = " (no cover art found)"
    }
    export.outputURL = tmp
    export.outputFileType = .m4a
    export.metadata = items
    let sem = DispatchSemaphore(value: 0)
    export.exportAsynchronously { sem.signal() }
    sem.wait()
    guard export.status == .completed else {
        try? FileManager.default.removeItem(at: tmp)
        return export.error?.localizedDescription ?? "could not write tags"
    }
    do {
        _ = try FileManager.default.replaceItemAt(src, withItemAt: tmp)
    } catch {
        return "could not replace the file: \(error.localizedDescription)"
    }
    return artNote.isEmpty ? nil : "tags written" + artNote
}

/// Debug: prints the tags of a file (run: yt-dlp-gui --readtags <file>). Opens no window.
func printTags(path: String) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    for item in asset.metadata {
        let id = item.identifier?.rawValue ?? item.key.map { "\($0)" } ?? "?"
        if let s = item.stringValue { print("\(id) = \(s)") }
        else if let d = item.dataValue { print("\(id) = <\(d.count) bytes> \(d.prefix(8).map { String(format: "%02x", $0) }.joined())") }
        else { print("\(id) = ?") }
    }
}
