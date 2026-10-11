// Draws the app icon (a play button on a blue rounded square) into <outdir>/AppIcon.iconset. Opens no window.
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // rounded square on the standard macOS icon grid (824 of 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.40, green: 0.52, blue: 0.98, alpha: 1), ending: NSColor(red: 0.16, green: 0.20, blue: 0.62, alpha: 1))!
        .draw(in: bodyPath, angle: -90)

    // play triangle, nudged right so it looks optically centred, with rounded corners
    let tri = NSBezierPath()
    tri.move(to: CGPoint(x: 392, y: 300))
    tri.line(to: CGPoint(x: 392, y: 724))
    tri.line(to: CGPoint(x: 748, y: 512))
    tri.close()
    tri.lineJoinStyle = .round
    tri.lineWidth = 56
    NSColor.white.setFill()
    NSColor.white.setStroke()
    tri.fill()
    tri.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1] + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: out)
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
}
print("wrote", out)
