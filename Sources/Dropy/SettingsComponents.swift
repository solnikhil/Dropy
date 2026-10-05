import AppKit
import SwiftUI
import DropyCore

/// Shared settings presentation keeps every pane on the same native Form layout.
/// System colors and controls follow appearance, contrast, and keyboard preferences.
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    if pane == .general {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable().frame(width: 58, height: 58)
                            .accessibilityHidden(true)
                    } else {
                        SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 48)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pane == .general ? "Dropy, your way." : pane.title)
                            .font(.system(size: 22, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                        Text(pane.subtitle)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
            }
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(.switch)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SettingsLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

struct SettingsBadge: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .fixedSize()
    }
}

struct SettingsNotice: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 20).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct Keycaps: View {
    let shortcut: KeyShortcut

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(shortcut.keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, cap.count > 1 ? 9 : 6)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.display)
    }
}

struct PermissionCard: View {
    let title: String
    let symbol: String
    let detail: String
    let requirement: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, tint: .blue, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(requirement).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Label(granted ? "Allowed" : "Not allowed",
                      systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(granted ? Color.green : Color.secondary)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !granted {
                HStack {
                    Spacer()
                    Button("Open System Settings…", action: action)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// An intentionally schematic desktop: it explains relative preset sizes without
/// capturing private window contents or implying a pixel-perfect preview.
struct OverlaySizePreview: View {
    let preset: SizePreset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var windowSize: CGSize {
        switch preset {
        case .compact: CGSize(width: 126, height: 76)
        case .medium: CGSize(width: 186, height: 112)
        case .wide: CGSize(width: 250, height: 144)
        case .nativeSize: CGSize(width: 164, height: 126)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .underPageBackgroundColor))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            // Menu bar and notch establish where the overlay belongs.
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Circle().frame(width: 4, height: 4)
                    Capsule().frame(width: 18, height: 3)
                    Spacer()
                    Capsule().frame(width: 12, height: 3)
                    Capsule().frame(width: 8, height: 3)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 11).frame(height: 16)
                Divider()
                Spacer()
            }
            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                .fill(Color(nsColor: .labelColor).opacity(0.8))
                .frame(width: 50, height: 11)
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in Circle().fill(.tertiary).frame(width: 4, height: 4) }
                    Spacer()
                    Capsule().fill(.quaternary).frame(width: 22, height: 3)
                }
                .padding(.horizontal, 9).frame(height: 20)
                Divider()
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<3) { index in
                            Capsule().fill(index == 0 ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.2))
                                .frame(height: 3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8).frame(width: windowSize.width * 0.28)
                    .frame(maxHeight: .infinity)
                    .background(.quaternary.opacity(0.4))
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.12))
                        Capsule().fill(.quaternary).frame(height: 3)
                        Capsule().fill(.quaternary).frame(width: windowSize.width * 0.33, height: 3)
                    }
                    .padding(9)
                }
            }
            .frame(width: windowSize.width, height: windowSize.height)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
            .padding(.top, 15)
        }
        .frame(width: 300, height: 180)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: preset)
        .accessibilityHidden(true)
    }
}

/// One material definition for both settings surfaces, with an opaque accessible
/// alternative and a vibrancy fallback for the app's macOS 15 deployment target.
struct SettingsGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background { surface }
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        } else if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
    }
}
