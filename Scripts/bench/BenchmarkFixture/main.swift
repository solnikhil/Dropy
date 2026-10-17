import AppKit

// Only generated content. The second window detects wrong-window delivery.
@MainActor
final class InputView: NSView {
    let label = NSTextField(labelWithString: "Dropy benchmark fixture")
    var records: [[String: Any]] = []
    var ticks = 0
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label.frame = CGRect(x: 25, y: 40, width: 430, height: 60)
        label.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("programmatic fixture") }
    func record(_ event: NSEvent, kind: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let sent = event.cgEvent?.timestamp ?? 0
        records.append(["sequence": event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
                        "kind": kind, "keyCode": Int(event.keyCode), "repeat": event.isARepeat,
                        "shift": event.modifierFlags.contains(.shift),
                        "latencyMs": sent > 0 && now >= sent ? Double(now - sent) / 1e6 : -1])
        label.stringValue = "Received \(records.count) events"
    }
    override func keyDown(with event: NSEvent) { record(event, kind: "down") }
    override func keyUp(with event: NSEvent) { record(event, kind: "up") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    func tick() {
        ticks += 1
        layer?.backgroundColor = NSColor(calibratedHue: CGFloat(ticks % 360) / 360, saturation: 0.4, brightness: 0.8, alpha: 1).cgColor
        label.stringValue = "Frame \(ticks)"
    }
}

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    var target: NSWindow!
    var decoy: NSWindow!
    var control: BenchmarkControl?
    var timer: Timer?
    let view = InputView(frame: CGRect(x: 0, y: 0, width: 500, height: 320))
    let other = InputView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    let directory: String
    let backdrop: Bool
    init(directory: String, backdrop: Bool) { self.directory = directory; self.backdrop = backdrop }
    func makeWindow(_ title: String, frame: CGRect, content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        target = makeWindow("Dropy benchmark target", frame: CGRect(x: 100, y: 120, width: 500, height: 320), content: view)
        if !backdrop {
            decoy = makeWindow("Dropy benchmark decoy", frame: CGRect(x: 650, y: 120, width: 300, height: 200), content: other)
            decoy.orderFront(nil)
        }
        target.makeKeyAndOrderFront(nil)
        target.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        control = BenchmarkControl(directory: directory) { [weak self] action in self?.command(action) ?? ["error": "gone"] }
    }
    func state(_ window: NSWindow) -> [String: Any] {
        let frame = window.frame
        return ["windowID": window.windowNumber, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                "minimized": window.isMiniaturized, "visible": window.isVisible,
                "fullscreen": window.styleMask.contains(.fullScreen), "key": window.isKeyWindow,
                "spaces": spaces(window.windowNumber)]
    }
    func command(_ action: String) -> [String: Any] {
        switch action {
        case "snapshot": break
        case "focus":
            target.makeKeyAndOrderFront(nil); target.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        case "reset": view.records = []; other.records = []
        case "animate":
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.view.tick() }
            }
        case "static": timer?.invalidate(); timer = nil
        case "fullscreen": if !target.styleMask.contains(.fullScreen) { target.toggleFullScreen(nil) }
        case "windowed": if target.styleMask.contains(.fullScreen) { target.toggleFullScreen(nil) }
        case "quit": DispatchQueue.main.async { NSApp.terminate(nil) }
        default: return ["error": "unknown fixture action"]
        }
        return ["target": state(target), "decoy": decoy.map(state) as Any? ?? NSNull(),
                "targetEvents": view.records, "decoyEvents": other.records,
                "hidden": NSApp.isHidden, "frontmost": NSApp.isActive, "ticks": view.ticks]
    }
    func spaces(_ window: Int) -> [UInt64] {
        typealias Connection = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        guard let a = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"),
              let b = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopySpacesForWindows"),
              let result = unsafeBitCast(b, to: Copy.self)(unsafeBitCast(a, to: Connection.self)(), 0x7,
                            [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return result.map(\.uint64Value)
    }
}

let args = CommandLine.arguments
let controlDirectory = ProcessInfo.processInfo.environment["DROPY_FIXTURE_CONTROL"]
    ?? args.firstIndex(of: "--control").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
if let controlDirectory {
    let app = NSApplication.shared
    let delegate = Fixture(directory: controlDirectory, backdrop: args.contains("--backdrop") || ProcessInfo.processInfo.environment["DROPY_FIXTURE_BACKDROP"] == "1")
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    fputs("usage: BenchmarkFixture --control <private directory> [--backdrop]\n", stderr)
    exit(2)
}
