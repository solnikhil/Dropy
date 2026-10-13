import AppKit
import SwiftUI
import DropyCore

private struct SettingsPaneKey: EnvironmentKey {
    static let defaultValue: SettingsPane? = nil
}

extension EnvironmentValues {
    var settingsPane: SettingsPane? {
        get { self[SettingsPaneKey.self] }
        set { self[SettingsPaneKey.self] = newValue }
    }
}

extension SettingsPane {
    var introduction: String {
        switch self {
        case .general: "Configure startup behavior and keyboard shortcuts."
        case .opening: "Choose what’s waiting when you open Dropy."
        case .overlay: "Find the right place. Give your apps room to breathe."
        case .animation: "Make every opening feel like yours."
        case .interaction: "Choose how your apps work inside Dropy."
        case .permissions: "You’re in control of what Dropy can access."
        case .advanced: "Reset preferences and view diagnostic information."
        case .about: "Version and project information."
        case .updates: "Check for published versions and view update status."
        }
    }
}

struct SettingsPageHeading: View {
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(pane.title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(pane.introduction)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }
}

/// Shared illustration language for Settings. This is schematic content, never a
/// captured window. Position uses the same geometry as the real overlay.
struct WorkspaceIllustration: View {
    var position: OverlayPosition = .notch
    var preset: SizePreset = .medium

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [Color(red: 0.17, green: 0.23, blue: 0.31),
                                        Color(red: 0.30, green: 0.37, blue: 0.44),
                                        Color(red: 0.55, green: 0.40, blue: 0.34)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse()
                    .fill(LinearGradient(colors: [Color(red: 0.94, green: 0.64, blue: 0.48).opacity(0.5), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: size.width * 0.9, height: size.height * 1.8)
                    .rotationEffect(.degrees(-35))
                    .offset(x: size.width * 0.4, y: size.height * 0.5)
                Canvas { context, canvas in
                    let menu = CGRect(x: 0, y: 0, width: canvas.width, height: 12)
                    context.fill(Path(menu), with: .color(.black.opacity(0.14)))
                    for index in 0..<3 {
                        let rect = CGRect(x: 12 + CGFloat(index) * 17, y: 5, width: 11, height: 2)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.5)))
                    }
                    let factor: CGFloat = preset == .compact ? 0.40 : preset == .wide ? 0.72 : 0.56
                    let screen = CGRect(origin: .zero, size: canvas)
                    let rect = position.body(size: CGSize(width: canvas.width * factor, height: canvas.height * 0.64),
                                             screen: screen, visible: screen)
                    let shape = NotchShape(body: rect, bottomRadius: 10, earRadius: 7, position: position)
                    let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
                    context.fill(Path(shape.fillPath).applying(flip), with: .color(Color(red: 0.055, green: 0.063, blue: 0.078)))
                    context.stroke(Path(shape.strokePath).applying(flip), with: .color(.white.opacity(0.20)), lineWidth: 0.7)
                    let body = rect.applying(flip)
                    let inset = max(3, body.width * 0.08)
                    let top = body.minY + max(6, body.height * 0.13)
                    let iconSide = min(20, body.width * 0.16)
                    let icon = CGRect(x: body.minX + inset, y: top, width: iconSide, height: iconSide)
                    context.fill(Path(roundedRect: icon, cornerRadius: 6), with: .color(SettingsTheme.accent.opacity(0.85)))
                    let title = CGRect(x: icon.maxX + iconSide * 0.4, y: top + iconSide * 0.2,
                                       width: max(3, body.width * 0.36), height: max(2, iconSide * 0.2))
                    context.fill(Path(roundedRect: title, cornerRadius: 2), with: .color(.white.opacity(0.7)))
                    for index in 0..<3 {
                        let row = CGRect(x: body.minX + inset,
                                         y: top + iconSide + max(4, body.height * 0.1) + CGFloat(index) * max(5, body.height * 0.12),
                                         width: max(3, body.width - inset * 2), height: max(2, min(10, body.height * 0.065)))
                        if row.maxY < body.maxY - max(3, body.height * 0.1) {
                            context.fill(Path(roundedRect: row, cornerRadius: 3), with: .color(.white.opacity(index == 0 ? 0.13 : 0.055)))
                        }
                    }
                    let notch = CGRect(x: canvas.width / 2 - 22, y: 0, width: 44, height: 9)
                    context.fill(Path(roundedRect: notch, cornerRadius: 3), with: .color(.black))
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Supporting technical consequences stay accessible without dominating the page.
struct SettingsExplanation: View {
    let title: String
    let text: String

    var body: some View {
        DisclosureGroup {
            Text(text)
                .font(SettingsMetrics.detail)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        } label: {
            Label(title, systemImage: "info.circle")
                .font(SettingsMetrics.detail)
                .foregroundStyle(.secondary)
        }
        .tint(SettingsTheme.accent)
        .settingsRow()
    }
}
