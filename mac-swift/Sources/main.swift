import Foundation

// Command-line modes that open no window:
//   --selftest                              run the logic checks
//   --download <url> <folder> <audio|video> download one link with the same code the window uses
let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(selfTest() ? 0 : 1)
}
if args.contains("--checkupdate") {   // asks GitHub for the latest release and says what the app would do (opens no window)
    let r = checkForUpdate()
    if let i = r.info { print("update available: \(i.version) (you have \(appVersion)) -> \(i.assetURL)") }
    else if !r.error.isEmpty { print("could not check: \(r.error)") }
    else { print("up to date (\(appVersion)); no newer release found") }
    exit(0)
}
if let i = args.firstIndex(of: "--search"), args.count > i + 2 {   // --search <song|album|artist|playlist> <words...>   (prints the results; opens no window)
    let kind = args[i + 1]
    let query = args[(i + 2)...].filter { $0 != "--albums" }.joined(separator: " ")
    var res = searchCatalog(kind: kind, query: query)
    if kind == "artist", let first = res.hits.first, args.contains("--albums") {   // also list the first artist's albums
        print("artist: \(first.title)")
        res = artistAlbums(artistID: String(first.id.split(separator: ":").last ?? ""))
    }
    if !res.error.isEmpty { print("error: \(res.error)") }
    for h in res.hits { print("\(h.id) | \(h.title) | \(h.subtitle) | \(h.detail)") }
    exit(0)
}
if let i = args.firstIndex(of: "--readtags"), args.count > i + 1 {
    printTags(path: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--download"), args.count > i + 2 {
    guard let base = findYtDlp(saved: nil) else { print("yt-dlp not found"); exit(1) }
    let mode = args.count > i + 3 ? args[i + 3] : "video"
    var chooser: ((SpotifyList) -> [Int]?)? = nil
    if let k = args.firstIndex(of: "--pick"), args.count > k + 1 {   // test only: --pick 1,3 pretends those songs were ticked in the picker
        let wanted = args[k + 1].split(separator: ",").compactMap { Int($0) }.map { $0 - 1 }
        chooser = { _ in wanted }
    }
    let jobs = planJobs(lines: [args[i + 1]], baseFolder: args[i + 2], log: { print("log: \($0)") }, choose: chooser)
    let runner = Runner()
    if let t = args.firstIndex(of: "--tiers"), args.count > t + 1 {   // test only: --tiers ytmusic,lyric,official,musicvideo,top
        let names = ["ytmusic": SearchSource.ytMusic, "lyric": .lyric, "official": .official, "musicvideo": .musicVideo, "top": .top]
        runner.sources = args[t + 1].split(separator: ",").compactMap { names[String($0)] }
    }
    runner.run(base: base, jobs: jobs, audio: mode == "audio", height: "720", playlist: false,
                 js: findJS(), ffmpeg: findFFmpeg(), audioFormat: "m4a") { print($0) }
    exit(0)
}
YtDlpGUIApp.main()
