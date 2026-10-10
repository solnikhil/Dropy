// Draws Dropy's app icon and writes Resources/AppIcon.icns.
//   swift Scripts/make-icon.swift
// A dark tile with the notch at its top edge and a window dropping out of it.
import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Dropy.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: an 824-point body centered in 1024, corner radius about 185.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSShadow().apply { $0.shadowColor = .black.withAlphaComponent(0.35); $0.shadowBlurRadius = 24 * s
        $0.shadowOffset = CGSize(width: 0, height: -10 * s) }
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)])!
        .draw(in: tile, angle: -90)
    NSShadow().apply { $0.shadowColor = nil }
    tile.addClip()

    // The notch, flush with the top edge.
    let notch = NSBezierPath(roundedRect: CGRect(x: 342 * s, y: 812 * s, width: 340 * s, height: 160 * s),
                             xRadius: 56 * s, yRadius: 56 * s)
    NSColor.black.setFill()
    notch.fill()

    // The window dropping out of it.
    let window = CGRect(x: 232 * s, y: 238 * s, width: 560 * s, height: 470 * s)
    let windowPath = NSBezierPath(roundedRect: window, xRadius: 64 * s, yRadius: 64 * s)
    NSShadow().apply { $0.shadowColor = NSColor(calibratedRed: 0.2, green: 0.6, blue: 1, alpha: 0.45)
        $0.shadowBlurRadius = 60 * s; $0.shadowOffset = .zero }
    NSGradient(colors: [NSColor(calibratedRed: 0.33, green: 0.80, blue: 1.00, alpha: 1),
                        NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.98, alpha: 1)])!
        .draw(in: windowPath, angle: -90)
    NSShadow().apply { $0.shadowColor = nil }
    // Title bar and content lines.
    NSColor.white.withAlphaComponent(0.9).setFill()
    for x in [292, 342, 392] {
        NSBezierPath(ovalIn: CGRect(x: CGFloat(x) * s, y: 630 * s, width: 30 * s, height: 30 * s)).fill()
    }
    NSColor.white.withAlphaComponent(0.55).setFill()
    for (y, width) in [(530, 420), (460, 340), (390, 380), (320, 260)] {
        NSBezierPath(roundedRect: CGRect(x: 292 * s, y: CGFloat(y) * s, width: CGFloat(width) * s, height: 34 * s),
                     xRadius: 17 * s, yRadius: 17 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) { configure(self); set() }
}

for points in [16, 32, 128, 256, 512] {
    try draw(size: CGFloat(points)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(size: CGFloat(points * 2)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = repo.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print(output.path)
