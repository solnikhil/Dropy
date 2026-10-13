import AppKit

/// Semantic colors shared by AppKit and SwiftUI. Dynamic colors follow the Mac's
/// appearance; accent is reserved for actions and selection, information for status.
enum DropyAppearance {
    static let accent = adaptive(dark: (1.0, 0.49, 0.40), light: (0.78, 0.25, 0.20))
    static let background = adaptive(dark: (0.105, 0.112, 0.125), light: (0.955, 0.950, 0.940))
    static let sidebar = adaptive(dark: (0.135, 0.143, 0.158), light: (0.925, 0.920, 0.910))
    static let card = adaptive(dark: (0.155, 0.165, 0.183), light: (1.0, 0.995, 0.985))
    static let information = adaptive(dark: (0.55, 0.72, 1.0), light: (0.12, 0.40, 0.78))

    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }
    }
}
