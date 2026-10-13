import AppKit

/// Semantic colors shared by AppKit and SwiftUI. Dynamic colors follow the Mac's
/// appearance; accent is reserved for actions and selection, information for status.
enum DropyAppearance {
    static let accent = adaptive(dark: 0xE87868, light: (0.78, 0.25, 0.20))
    static let background = adaptive(dark: 0x0E0E10, light: (0.955, 0.950, 0.940))
    static let sidebar = adaptive(dark: 0x0A0A0C, light: (0.925, 0.920, 0.910))
    static let card = adaptive(dark: 0x171719, light: (1.0, 0.995, 0.985))
    static let control = adaptive(dark: 0x202023, light: (0.925, 0.920, 0.910))
    static let controlHover = adaptive(dark: 0x2A2A2E, light: (0.89, 0.885, 0.875))
    static let selection = adaptive(dark: 0x222225, light: (0.89, 0.885, 0.875))
    static let text = adaptive(dark: 0xF0F0F2, light: (0.11, 0.11, 0.12))
    static let secondaryText = adaptive(dark: 0xA1A1AA, light: (0.38, 0.38, 0.41))
    static let information = adaptive(dark: 0x8CB8FF, light: (0.12, 0.40, 0.78))

    private static func adaptive(dark: UInt32, light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let darkRGB = (CGFloat((dark >> 16) & 255) / 255, CGFloat((dark >> 8) & 255) / 255, CGFloat(dark & 255) / 255)
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkRGB : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }
    }
}
