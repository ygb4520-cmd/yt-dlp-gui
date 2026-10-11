import Foundation

// Command-line modes that open no window:
//   --selftest                              run the logic checks
//   --download <url> <folder> <audio|video> download one link with the same code the window uses
let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(selfTest() ? 0 : 1)
}
if let i = args.firstIndex(of: "--download"), args.count > i + 2 {
    guard let base = findYtDlp(saved: nil) else { print("yt-dlp not found"); exit(1) }
    let mode = args.count > i + 3 ? args[i + 3] : "video"
    Runner().run(base: base, urls: [args[i + 1]], audio: mode == "audio", height: "720", folder: args[i + 2],
                 playlist: false, js: findJS(), ffmpeg: findFFmpeg()) { print($0) }
    exit(0)
}
YtDlpGUIApp.main()
