import Foundation
import os

private let diagnosticLog = Logger(subsystem: "org.dropy.app", category: "diagnostics")

/// Dropy's diagnostics, readable with
/// `log show --predicate 'subsystem == "org.dropy.app"'`. Foundation's NSLog writes
/// them to the system log as `<private>`, which hid why a docking failed. This
/// module-level function takes the place of NSLog for every call in the app. The
/// messages hold window IDs, app names and error codes, never window contents.
func NSLog(_ format: String, _ arguments: CVarArg...) {
    let message = String(format: format, arguments: arguments)
    diagnosticLog.notice("\(message, privacy: .public)")
}
