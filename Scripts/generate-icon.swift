import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let catalog = root.appendingPathComponent("WakeLeaseApp/Assets.xcassets/AppIcon.appiconset")
let iconset = root.appendingPathComponent(".build/WakeLease.iconset")
try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func draw(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = color(21, 32, 53)
    let blue = color(57, 111, 216)
    let paper = color(240, 245, 253)
    background.setFill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 194, yRadius: 194).fill()
    blue.setFill()
    NSBezierPath(roundedRect: NSRect(x: 207, y: 419, width: 524, height: 355), xRadius: 58, yRadius: 58).fill()
    paper.setFill()
    NSBezierPath(roundedRect: NSRect(x: 255, y: 250, width: 563, height: 370), xRadius: 58, yRadius: 58).fill()
    background.setFill()
    NSBezierPath(ovalIn: NSRect(x: 222, y: 400, width: 66, height: 66)).fill()
    NSBezierPath(ovalIn: NSRect(x: 785, y: 400, width: 66, height: 66)).fill()
    blue.setFill()
    NSBezierPath(ovalIn: NSRect(x: 374, y: 364, width: 136, height: 136)).fill()
    NSBezierPath(roundedRect: NSRect(x: 477, y: 412, width: 188, height: 40), xRadius: 14, yRadius: 14).fill()
    NSBezierPath(roundedRect: NSRect(x: 603, y: 366, width: 38, height: 77), xRadius: 10, yRadius: 10).fill()
    paper.setFill()
    NSBezierPath(ovalIn: NSRect(x: 410, y: 400, width: 64, height: 64)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let data = draw(size: size * scale)
        try data.write(to: catalog.appendingPathComponent(name))
        try data.write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "WakeLease", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: catalog.appendingPathComponent("Contents.json"))
