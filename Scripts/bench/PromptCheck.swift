// Lists macOS permission and security prompts on screen (owner and bounds), one per line,
// and exits 1 when any is visible. Device sessions refuse to start while one is up:
// synthetic clicks or keys could land on it and answer it. Reads only window-server
// metadata (no titles or pixels).
import CoreGraphics
import Foundation

let owners: Set<String> = ["UserNotificationCenter", "SecurityAgent", "universalAccessAuthWarn",
                           "CoreServicesUIAgent", "tccd", "coreautha"]
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var found = 0
for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owners.contains(owner),
          let raw = window[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: raw),
          frame.width > 40, frame.height > 40 else { continue }
    found += 1
    print("\(owner) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
}
exit(found == 0 ? 0 : 1)
