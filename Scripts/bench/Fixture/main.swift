// A disposable source app for device checks. It shows one animated window and can
// move that window between Spaces on request, so off-Space behaviour is reproducible
// without switching the person's desktop or touching their documents.
//
// Built into .build/local/DropyFixture.app (bundle ID org.dropy.fixture) by
// Scripts/device-checks.sh. Commands arrive as distributed notifications named
// "org.dropy.fixture.command" whose object is one of:
//   space:<id>   move the window to that Space (private SkyLight call, own window only)
//   space:other  move it to another ordinary desktop Space on its display
//   space:home   move it back to the Space it opened on
//   second       open a second window, which becomes main and key
//   quit
// State is printed to stdout as "fixture window=<id> space=<id>" after each change.
import AppKit

private typealias MainConnection = @convention(c) () -> Int32
private typealias MoveToSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

private func symbol<T>(_ name: String, as type: T.Type) -> T? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var extra: [NSWindow] = []
    private var home: UInt64 = 0
    private var ticks = 0
    private let label = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 120, y: 140, width: 640, height: 400),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Dropy fixture"
        window.isReleasedWhenClosed = false
        label.font = .monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        label.frame = CGRect(x: 40, y: 160, width: 560, height: 80)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Keep producing frames, so capture continuity is observable.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: .init("org.dropy.fixture.command"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            home = spaces().first ?? 0
            report()
        }
    }

    private func tick() {
        ticks += 1
        label.stringValue = "frame \(ticks)"
    }

    /// An ordinary desktop Space other than the window's own, on the same display.
    /// Full-screen and tiled Spaces are skipped. Nil when there is only one desktop.
    private func otherSpace() -> UInt64? {
        typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let copy = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let current = spaces()
        for display in displays {
            let desktops = (display["Spaces"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? Int) == 0 }.compactMap { $0["id64"] as? UInt64 }
            guard desktops.contains(where: current.contains) else { continue }
            return desktops.first { !current.contains($0) }
        }
        return nil
    }

    private func spaces() -> [UInt64] {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let copy = symbol("CGSCopySpacesForWindows", as: CopySpaces.self),
              let list = copy(connection, 0x7, [NSNumber(value: window.windowNumber)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] else { return [] }
        return list.map(\.uint64Value)
    }

    private func report() {
        print("fixture window=\(window.windowNumber) space=\(spaces().map(String.init).joined(separator: ","))")
        fflush(stdout)
    }

    @objc private func command(_ notification: Notification) {
        guard let command = notification.object as? String else { return }
        if command == "quit" { NSApp.terminate(nil); return }
        if command == "second" {
            // A second window that becomes main and key, so the first is neither.
            let second = NSWindow(contentRect: CGRect(x: 820, y: 140, width: 320, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            second.title = "Dropy fixture second"
            second.isReleasedWhenClosed = false
            second.makeKeyAndOrderFront(nil)
            extra.append(second)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                print("fixture second=\(second.windowNumber)")
                fflush(stdout)
            }
            return
        }
        guard command.hasPrefix("space:") else { return }
        let argument = command.dropFirst("space:".count)
        let target: UInt64? = switch argument {
        case "home": home
        case "other": otherSpace()
        default: UInt64(argument)
        }
        guard let target,
              let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let move = symbol("CGSMoveWindowsToManagedSpace", as: MoveToSpace.self) else {
            print("fixture error=unsupported \(command)")
            fflush(stdout)
            return
        }
        move(connection, [NSNumber(value: window.windowNumber)] as CFArray, target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in report() }
    }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
