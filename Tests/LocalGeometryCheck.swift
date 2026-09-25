import CoreGraphics
import Foundation
import DropyCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let screen = CGRect(x: 100, y: 50, width: 1000, height: 700)
let overlay = OverlayGeometry.frame(on: screen, preferredSize: CGSize(width: 1200, height: 400))
check(overlay == CGRect(x: 100, y: 350, width: 1000, height: 400), "overlay top centering")

let fit = ContentTransform(sourceRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                           destinationRect: CGRect(x: 0, y: 0, width: 400, height: 400),
                           mode: .fit)
check(fit.sourcePoint(for: CGPoint(x: 200, y: 50)) == nil, "letterbox must not accept input")
check(fit.sourcePoint(for: CGPoint(x: 200, y: 200)) == CGPoint(x: 200, y: 100), "fit center mapping")

let fill = ContentTransform(sourceRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                            destinationRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                            mode: .fill)
check(fill.sourcePoint(for: CGPoint(x: 0, y: 100)) == CGPoint(x: 100, y: 100), "fill left crop")
check(fill.sourcePoint(for: CGPoint(x: 199, y: 100)) == CGPoint(x: 299, y: 100), "fill right crop")

let selected = ContentTransform(sourceRect: CGRect(x: 300, y: 150, width: 200, height: 100),
                                destinationRect: CGRect(x: 20, y: 20, width: 200, height: 100),
                                mode: .selectedRegion)
check(selected.sourcePoint(for: CGPoint(x: 120, y: 70)) == CGPoint(x: 400, y: 200), "selected region offset")

var preferences = DropyPreferences()
preferences.openBehavior = .lastUsed
preferences.lastUsedBundleIdentifier = "com.example.target"
let encoded = try JSONEncoder().encode(preferences)
let decoded = try JSONDecoder().decode(DropyPreferences.self, from: encoded)
check(decoded == preferences, "preference persistence round trip")

let source = WindowIdentity(processID: 100, processLaunchDate: Date(timeIntervalSince1970: 1_000),
                            windowID: 42, bundleIdentifier: "org.example.editor")
check(source.matches(source), "exact source window matches")
check(!source.matches(WindowIdentity(processID: 101, processLaunchDate: source.processLaunchDate,
                                     windowID: 42, bundleIdentifier: "org.example.editor")),
      "reused window ID in another process must not match")
check(!source.matches(WindowIdentity(processID: 100,
                                     processLaunchDate: Date(timeIntervalSince1970: 1_010),
                                     windowID: 42, bundleIdentifier: "org.example.editor")),
      "reused PID after relaunch must not match")
check(!source.matches(WindowIdentity(processID: 100, processLaunchDate: source.processLaunchDate,
                                     windowID: 43, bundleIdentifier: "org.example.editor")),
      "another document window must not match")
print("DropyCore checks passed")
