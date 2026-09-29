// Input target for the M3 exact-window input harness (issue #8). A disposable app with
// two identical windows, A and B, each holding a text field, a button, a scroll view and
// a per-window menu command. Every event the app receives and every effect it causes is
// written as one JSON line to the log, tagged with the window that received it, so a
// harness can tell an event that reached the intended window from one that reached the
// other window, or nothing.
//
// Launch through LaunchServices (the harness needs an exact process identity):
//   open -n DropyInputFixture.app --args --log <path.jsonl>
// Commands arrive as distributed notifications "org.dropy.inputfixture.command":
//   state:<nonce>   write {"kind":"state",...} with both windows' effects and focus
//   reset           clear text, press counts and scroll offsets
//   key:A|key:B     make that window key (and activate the app)
//   space:other|space:home   move window A to another desktop or back (private SkyLight)
//   rebuild:A|rebuild:B      replace that window's text field with a new one, so an
//                            Accessibility element resolved earlier becomes stale
//   quit
// Logs contain only synthetic test content typed by the harness.
import AppKit

private typealias MainConnection = @convention(c) () -> Int32
private typealias MoveToSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

private func symbol<T>(_ name: String, as type: T.Type) -> T? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
}

@MainActor
final class Log {
    static var handle: FileHandle?
    static let start = Date()

    static func write(_ object: [String: Any]) {
        var line = object
        line["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        handle?.write(data + Data("\n".utf8))
    }
}

/// One test window: its controls and the effects they recorded.
@MainActor
final class TestWindow: NSObject, NSTextFieldDelegate {
    let name: String
    let window: NSWindow
    var field = NSTextField(string: "")
    let button = NSButton(title: "Press", target: nil, action: nil)
    let scroll = NSScrollView()
    var presses = 0
    var commands = 0

    init(name: String, frame: CGRect) {
        self.name = name
        window = InputWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
        super.init()
        window.title = "Dropy input \(name)"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        field.frame = CGRect(x: 20, y: frame.height - 50, width: frame.width - 140, height: 26)
        field.setAccessibilityIdentifier("text")
        field.delegate = self
        button.frame = CGRect(x: frame.width - 110, y: frame.height - 52, width: 90, height: 30)
        button.setAccessibilityIdentifier("button")
        button.target = self
        button.action = #selector(pressed)
        scroll.frame = CGRect(x: 20, y: 20, width: frame.width - 40, height: frame.height - 90)
        scroll.hasVerticalScroller = true
        scroll.setAccessibilityIdentifier("scroll")
        // Flipped, so the view starts at the top and scrolling down has room to move.
        let document = FlippedView(frame: CGRect(x: 0, y: 0, width: frame.width - 60, height: 4000))
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        for view in [field, button, scroll] as [NSView] { content.addSubview(view) }
        window.contentView = content
        (window as? InputWindow)?.label = name
    }

    var scrollOffset: Double { Double(scroll.contentView.bounds.origin.y) }

    func state() -> [String: Any] {
        ["id": window.windowNumber, "text": field.stringValue, "presses": presses, "commands": commands,
         "scroll": scrollOffset.rounded(), "key": window.isKeyWindow, "main": window.isMainWindow,
         "minimized": window.isMiniaturized, "onScreen": window.occlusionState.contains(.visible),
         "firstResponderIsText": window.firstResponder === field.currentEditor() ||
            window.firstResponder === field]
    }

    /// Swaps in a fresh text field with the same identifier and frame.
    func rebuildField() {
        let replacement = NSTextField(string: field.stringValue)
        replacement.frame = field.frame
        replacement.setAccessibilityIdentifier("text")
        replacement.delegate = self
        field.superview?.replaceSubview(field, with: replacement)
        field = replacement
        Log.write(["kind": "rebuilt", "w": name])
    }

    func reset() {
        field.stringValue = ""
        presses = 0
        commands = 0
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func pressed() {
        presses += 1
        Log.write(["kind": "effect", "w": name, "effect": "press", "count": presses])
    }

    @objc private func scrolled() {
        Log.write(["kind": "effect", "w": name, "effect": "scroll", "offset": scrollOffset.rounded()])
    }

    func controlTextDidChange(_ notification: Notification) {
        Log.write(["kind": "effect", "w": name, "effect": "text", "length": field.stringValue.count])
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Logs every event AppKit routes to the window, before normal handling.
final class InputWindow: NSWindow {
    var label = "?"
    override func sendEvent(_ event: NSEvent) {
        let name = label
        MainActor.assumeIsolated { if let line = describe(event, window: name) { Log.write(line) } }
        super.sendEvent(event)
    }
}

/// Input event types worth logging; window-management noise is skipped.
let loggedTypes: [NSEvent.EventType: String] = [
    .keyDown: "keyDown", .keyUp: "keyUp", .flagsChanged: "flagsChanged",
    .leftMouseDown: "leftMouseDown", .leftMouseUp: "leftMouseUp", .rightMouseDown: "rightMouseDown",
    .scrollWheel: "scrollWheel", .leftMouseDragged: "leftMouseDragged"]

@MainActor
func describe(_ event: NSEvent, window: String) -> [String: Any]? {
    guard let type = loggedTypes[event.type] else { return nil }
    var out: [String: Any] = ["kind": "event", "w": window, "type": type, "eventWindow": event.windowNumber]
    switch event.type {
    case .keyDown, .keyUp:
        out["keyCode"] = Int(event.keyCode)
        out["chars"] = event.charactersIgnoringModifiers ?? ""
        out["cmd"] = event.modifierFlags.contains(.command)
    case .scrollWheel:
        out["dy"] = Double(event.scrollingDeltaY)
    case .leftMouseDown, .leftMouseUp:
        out["x"] = Double(event.locationInWindow.x).rounded()
        out["y"] = Double(event.locationInWindow.y).rounded()
    default: break
    }
    return out
}

/// Logs events that reach the app without a window (a routing miss).
final class InputApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.window == nil, [.keyDown, .leftMouseDown, .scrollWheel].contains(event.type) {
            MainActor.assumeIsolated { if let line = describe(event, window: "none") { Log.write(line) } }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class InputFixture: NSObject, NSApplicationDelegate {
    private var windows: [TestWindow] = []
    private var home: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--log"), index + 1 < arguments.count {
            FileManager.default.createFile(atPath: arguments[index + 1], contents: nil)
            Log.handle = FileHandle(forWritingAtPath: arguments[index + 1])
        }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let testItem = NSMenuItem()
        let testMenu = NSMenu(title: "Test")
        // A key-window command, to see which window a shortcut acts on.
        testMenu.addItem(NSMenuItem(title: "Count in key window", action: #selector(countCommand), keyEquivalent: "k"))
        testItem.submenu = testMenu
        menu.addItem(appItem)
        menu.addItem(testItem)
        NSApp.mainMenu = menu
        windows = [TestWindow(name: "A", frame: CGRect(x: 100, y: 300, width: 520, height: 380)),
                   TestWindow(name: "B", frame: CGRect(x: 660, y: 300, width: 520, height: 380))]
        let center = NotificationCenter.default
        for test in windows {
            for (name, label) in [(NSWindow.didBecomeKeyNotification, "becameKey"), (NSWindow.didResignKeyNotification, "resignedKey"),
                                  (NSWindow.didBecomeMainNotification, "becameMain"), (NSWindow.didMiniaturizeNotification, "minimized"),
                                  (NSWindow.didDeminiaturizeNotification, "deminimized")] {
                center.addObserver(forName: name, object: test.window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        Log.write(["kind": "focus", "w": test.name, "change": label])
                        // Typing into whichever window is key edits its field, so a key event
                        // delivered to the wrong window shows up as a text change there.
                        if label == "becameKey" { test.window.makeFirstResponder(test.field) }
                    }
                }
            }
            test.window.makeKeyAndOrderFront(nil)
        }
        for (name, label) in [(NSApplication.didBecomeActiveNotification, "appActive"),
                              (NSApplication.didResignActiveNotification, "appInactive")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Log.write(["kind": "focus", "w": "app", "change": label]) }
            }
        }
        NSApp.activate()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: .init("org.dropy.inputfixture.command"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            home = spaces(of: windows[0].window).first ?? 0
            Log.write(["kind": "ready", "pid": Int(getpid()), "A": windows[0].window.windowNumber,
                       "B": windows[1].window.windowNumber])
        }
    }

    @objc private func countCommand() {
        guard let key = windows.first(where: { $0.window.isKeyWindow }) else {
            Log.write(["kind": "effect", "w": "none", "effect": "command"])
            return
        }
        key.commands += 1
        Log.write(["kind": "effect", "w": key.name, "effect": "command", "count": key.commands])
    }

    @objc private func command(_ notification: Notification) {
        guard let command = notification.object as? String else { return }
        switch command {
        case "quit":
            NSApp.terminate(nil)
        case "reset":
            windows.forEach { $0.reset() }
            Log.write(["kind": "reset"])
        case "key:A", "key:B":
            let target = windows[command == "key:A" ? 0 : 1]
            NSApp.activate()
            target.window.makeKeyAndOrderFront(nil)
        case "rebuild:A", "rebuild:B":
            windows[command == "rebuild:A" ? 0 : 1].rebuildField()
        case "space:other", "space:home":
            moveA(toHome: command == "space:home")
        default:
            if command.hasPrefix("state:") {
                var line: [String: Any] = ["kind": "state", "nonce": String(command.dropFirst("state:".count)),
                                           "active": NSApp.isActive]
                for test in windows { line[test.name] = test.state() }
                Log.write(line)
            }
        }
    }

    private func spaces(of window: NSWindow) -> [UInt64] {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let copy = symbol("CGSCopySpacesForWindows", as: CopySpaces.self),
              let list = copy(connection, 0x7, [NSNumber(value: window.windowNumber)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] else { return [] }
        return list.map(\.uint64Value)
    }

    private func moveA(toHome: Bool) {
        let window = windows[0].window
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let move = symbol("CGSMoveWindowsToManagedSpace", as: MoveToSpace.self),
              let copy = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else {
            Log.write(["kind": "space", "error": "unsupported"])
            return
        }
        let current = spaces(of: window)
        var target: UInt64? = toHome ? home : nil
        if !toHome {
            for display in displays {
                let desktops = (display["Spaces"] as? [[String: Any]] ?? [])
                    .filter { ($0["type"] as? Int) == 0 }.compactMap { $0["id64"] as? UInt64 }
                if desktops.contains(where: current.contains) { target = desktops.first { !current.contains($0) } }
            }
        }
        guard let target else {
            Log.write(["kind": "space", "error": "noOtherDesktop"])
            return
        }
        move(connection, [NSNumber(value: window.windowNumber)] as CFArray, target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            Log.write(["kind": "space", "A": spaces(of: window).map { Int($0) }])
        }
    }
}

let app = InputApplication.shared
let delegate = InputFixture()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
