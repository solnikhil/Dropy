import AppKit
import ScreenCaptureKit
import CoreMedia

// Top-edge probe for the benchmark: streams the strip under the notch at 120 fps for N
// seconds and counts frames where the overlay is not flush with the top of the screen:
// its black body shows 12 points down, but the topmost pixel rows above it do not.
final class Probe: NSObject, SCStreamOutput {
    var frames = 0, gaps = 0, lastGap = -10
    var events: [String] = []
    let start = Date()
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), bpr = CVPixelBufferGetBytesPerRow(px)
        let p = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        func lum(_ x: Int, _ y: Int) -> Int { let o = y*bpr + x*4; return (Int(p[o])+Int(p[o+1])+Int(p[o+2]))/3 }
        frames += 1
        // Black run at the probe row, around the center.
        let probe = 24, mid = w / 2
        guard lum(mid, probe) < 12 else { return }
        var l = mid, r = mid
        while l > 0 && lum(l-1, probe) < 12 { l -= 1 }
        while r < w-1 && lum(r+1, probe) < 12 { r += 1 }
        guard r - l > 200 else { return }
        // Columns well inside the body; the topmost rows there must be black too.
        var lit = 0, n = 0
        for x in stride(from: l + 30, to: r - 30, by: 4) { n += 1; if lum(x, 0) > 24 || lum(x, 1) > 24 { lit += 1 } }
        if n > 0 && lit * 2 > n {
            gaps += 1
            var top = 0; while top < probe && lum(l + 40, top) > 24 { top += 1 }
            events.append(String(format: "t=%.3f gap=%dpx body=%d-%d", Date().timeIntervalSince(start), top, l, r))
        }
    }
}

enum ProbeFailure: Error { case invalidDuration, mainDisplayUnavailable }

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? .nan
let probe = Probe()
_ = Task {
    do {
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else { throw ProbeFailure.invalidDuration }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw ProbeFailure.mainDisplayUnavailable
        }
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: CGFloat(display.width) / 2 - 500, y: 0, width: 1000, height: 30)
        config.width = 2000; config.height = 60
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 8
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe"))
        try await stream.startCapture()
        print("probe: capturing"); fflush(stdout)
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        print("probe: frames=\(probe.frames) gapFrames=\(probe.gaps)")
        probe.events.forEach { print("  " + $0) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("probe: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
