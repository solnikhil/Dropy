import AppKit
import DropyCore

@main struct LocalRegionRendererCheck {
    @MainActor static func main() throws {
        // Construct only: no window is ordered, no capture and no synthetic input.
        // make() compiles the Metal sampling shader and pipeline on the actual device.
        _ = NSApplication.shared
        let view = try MetalFrameView.make(frame: CGRect(x: 0, y: 0, width: 600, height: 360))
        precondition(!view.isSelectingRegion)
        view.isSelectingRegion = true
        view.clear()
        view.isSelectingRegion = false
        precondition(view.presentedFrame == nil)
        print("Region renderer pipeline checks passed")
    }
}
