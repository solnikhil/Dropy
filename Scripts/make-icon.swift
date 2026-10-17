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
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DropyIcon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("Dropy.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    artwork.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                 operation: .copy, fraction: 1)
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
