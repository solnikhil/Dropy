// Packages the current brand artwork into every macOS app-icon representation.
//   swift Scripts/make-icon.swift
//   swift Scripts/make-icon.swift --output /path/to/AppIcon.icns
import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--output") else {
    fputs("Usage: swift Scripts/make-icon.swift [--output /path/to/AppIcon.icns]\n", stderr)
    exit(2)
}
let output = arguments.isEmpty ? repo.appendingPathComponent("Resources/AppIcon.icns")
    : URL(fileURLWithPath: arguments[1])
let source = repo.appendingPathComponent("Resources/Brand/dropy-option-merged-v3.png")
guard let artwork = NSImage(contentsOf: source),
      let bitmap = NSBitmapImageRep(data: try Data(contentsOf: source)),
      bitmap.pixelsWide == bitmap.pixelsHigh, bitmap.pixelsWide >= 1024 else {
    fatalError("The app icon needs square brand artwork of at least 1024 pixels: \(source.path)")
}
// Points equal pixels, so the crop below is in the artwork's own pixels.
artwork.size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DropyIcon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("Dropy.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

// macOS 26 and later put an icon that leaves a transparent margin around its tile in
// a grey frame ("legacy" icon). Filling the whole canvas lets macOS apply its own
// rounded mask, so Dropy looks like a current app. The artwork's opaque tile is found,
// a centred square inside it (past the anti-aliased corners) is cropped, and the
// tile's edge colour fills behind it.
let tile: (crop: CGRect, fill: NSColor) = {
    let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX > minX, maxY > minY else { fatalError("The brand artwork has no opaque tile: \(source.path)") }
    let inset = 3
    let side = min(maxX - minX, maxY - minY) + 1 - 2 * inset
    let left = (minX + maxX + 1 - side) / 2, top = (minY + maxY + 1 - side) / 2
    let fill = bitmap.colorAt(x: (minX + maxX) / 2, y: minY + (maxY - minY) / 12) ?? .black
    // Bitmap rows run top-down; drawing rects run bottom-up.
    return (CGRect(x: left, y: h - top - side, width: side, height: side), fill.withAlphaComponent(1))
}()

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    tile.fill.setFill()
    canvas.fill()
    artwork.draw(in: canvas, from: tile.crop, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let generated = temporary.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", generated.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data(contentsOf: generated).write(to: output, options: .atomic)
print(output.path)
