import AppKit
import SwiftUI
import DropyCore

/// SwiftUI adapters for the shared semantic palette, plus interaction surface tints.
enum SettingsTheme {
    static let accent = Color(nsColor: DropyAppearance.accent)
    static let background = Color(nsColor: DropyAppearance.background)
    static let sidebar = Color(nsColor: DropyAppearance.sidebar)
    static let card = Color(nsColor: DropyAppearance.card)
    static let badge = Color(nsColor: DropyAppearance.information)
    static let text = Color(nsColor: DropyAppearance.text)
    static let secondaryText = Color(nsColor: DropyAppearance.secondaryText)
    static let separator = Color.primary.opacity(0.06)
    static let control = Color(nsColor: DropyAppearance.control)
    static let controlHover = Color(nsColor: DropyAppearance.controlHover)
    static let selection = Color(nsColor: DropyAppearance.selection)
    static let iconTile = Color(white: 0.30)
}

/// The one type scale and set of dimensions every settings view draws from, so the
/// sidebar, cards, rows and controls line up with each other.
enum SettingsMetrics {
    // Type: a 13-point body with a readable 12-point supporting line.
    static let body = Font.system(size: 13)
    static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    static let header = Font.system(size: 13, weight: .semibold)
    static let detail = Font.system(size: 12)
    static let badge = Font.system(size: 10, weight: .medium)

    // Controls: every button, menu and choice is the same height and corner.
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 8
    static let controlSpacing: CGFloat = 8

    // Cards and rows.
    static let cardRadius: CGFloat = 12
    static let cardSpacing: CGFloat = 20
    static let rowHeight: CGFloat = 44
    static let rowInset: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 9

    // Window layout.
    static let titleBarHeight: CGFloat = 52
    static let pageInset: CGFloat = 28
    static let iconSize: CGFloat = 20

    // Sidebar.
    static let sidebarInset: CGFloat = 10
    static let sidebarRowHeight: CGFloat = 32
    static let sidebarWidth: ClosedRange<CGFloat> = 180...320
    static let sidebarDefaultWidth: CGFloat = 208
}

/// Opaque by design: the navigation surface is stable against every wallpaper and
/// does not require a separate Reduce Transparency fallback.
struct SettingsSidebarSurface: View {
    var body: some View { SettingsTheme.sidebar }
}

/// A centered, bounded reading column. The page heading follows its navigation context.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.settingsPane) private var pane

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                if let pane { SettingsPageHeading(pane: pane) }
                content
            }
            .padding(.horizontal, SettingsMetrics.pageInset)
            .padding(.bottom, SettingsMetrics.pageInset)
            .padding(.top, 8)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
        .toggleStyle(.switch)
        .tint(SettingsTheme.accent)
        .foregroundStyle(SettingsTheme.text)
    }
}

/// A rounded group of rows divided by inset hairlines, with an optional title above
/// and an explanation below.
struct SettingsCard<Content: View>: View {
    var title: String?
    var badge: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String? = nil, badge: String? = nil, footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: SettingsMetrics.controlSpacing) {
                    Text(title).font(SettingsMetrics.header)
                        .accessibilityAddTraits(.isHeader)
                    if let badge { SettingsBadge(badge) }
                }
                .padding(.horizontal, SettingsMetrics.rowInset)
                .padding(.bottom, 8)
            }
            DividedRows { content }
                .background(SettingsTheme.card,
                            in: RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.045), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            if let footer {
                SettingsFootnote(footer)
                    .padding(.horizontal, SettingsMetrics.rowInset).padding(.top, 8)
            }
        }
    }
}

/// Puts a hairline between consecutive rows of a card.
private struct DividedRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(SettingsTheme.separator).frame(height: 1)
                            .padding(.horizontal, SettingsMetrics.rowInset)
                    }
                    row
                }
            }
        }
    }
}

/// The layout every card row shares: inset, height and spacing. Rows with their own
/// arrangement (an app icon, a status glyph) use this so they still line up.
struct SettingsRowFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

extension View {
    func settingsRow() -> some View { modifier(SettingsRowFrame()) }
}

/// One line of a card: a title with an optional explanation, and its controls on the
/// trailing edge.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var badge: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, detail: String? = nil, badge: String? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: SettingsMetrics.rowInset) {
            SettingsLabel(title, detail: detail, badge: badge)
            Spacer(minLength: SettingsMetrics.rowInset)
            HStack(spacing: SettingsMetrics.controlSpacing) { accessory }
        }
        .settingsRow()
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(_ title: String, detail: String? = nil, badge: String? = nil) {
        self.init(title, detail: detail, badge: badge) { EmptyView() }
    }
}

/// A row whose whole content is a switch, so the title is the switch's label.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    var badge: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, badge: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(title, detail: detail, badge: badge)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .settingsRow()
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityHint(detail ?? "")
    }
}

struct SettingsLabel: View {
    let title: String
    let detail: String?
    let badge: String?

    init(_ title: String, detail: String? = nil, badge: String? = nil) {
        self.title = title
        self.detail = detail
        self.badge = badge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: SettingsMetrics.controlSpacing) {
                Text(title).font(SettingsMetrics.bodyEmphasis)
                if let badge { SettingsBadge(badge) }
            }
            if let detail {
                Text(detail).font(SettingsMetrics.detail).foregroundStyle(SettingsTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A trailing read-only value, such as a version number.
struct SettingsValue: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(SettingsMetrics.body.monospacedDigit()).foregroundStyle(.secondary)
    }
}

/// Explanatory text under a card, or an error under a row.
struct SettingsFootnote: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(SettingsMetrics.detail)
            .foregroundStyle(isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(SettingsTheme.secondaryText))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A squircle tile with a white glyph, used beside sidebar and search rows.
struct SettingsIcon: View {
    let symbol: String
    var tint: Color = SettingsTheme.iconTile
    var size: CGFloat = SettingsMetrics.iconSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// A plain glyph in the same slot as an icon tile, for rows inside cards.
struct SettingsGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: SettingsMetrics.iconSize)
            .accessibilityHidden(true)
    }
}

struct SettingsBadge: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(SettingsMetrics.badge)
            .foregroundStyle(SettingsTheme.badge)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(SettingsTheme.badge.opacity(0.16), in: Capsule())
            .fixedSize()
    }
}

/// A short explanation inside a card, for states such as a missing permission.
struct SettingsNotice<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    init(symbol: String, title: String, detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.rowInset) {
            SettingsGlyph(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SettingsMetrics.bodyEmphasis)
                Text(detail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SettingsMetrics.rowInset)
            accessory
        }
        .settingsRow()
    }
}

extension SettingsNotice where Accessory == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// A filled, softly rounded push button. `outlined` adds the hairline used for the
/// one call to action in a card; `circular` is for icon-only buttons.
struct SettingsButtonStyle: ButtonStyle {
    var outlined = false
    var circular = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, outlined: outlined, circular: circular)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let outlined: Bool
    let circular: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var hover = HoverState()

    var body: some View {
        let height = SettingsMetrics.controlHeight
        let shape = RoundedRectangle(cornerRadius: circular ? height / 2 : SettingsMetrics.controlRadius,
                                     style: .continuous)
        configuration.label
            .font(outlined ? SettingsMetrics.bodyEmphasis : SettingsMetrics.body)
            .foregroundStyle(outlined ? SettingsTheme.accent : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, circular ? 0 : 10)
            .frame(minWidth: circular ? height : nil, minHeight: height)
            .background(outlined ? SettingsTheme.accent.opacity(hover.isHovered ? 0.22 : 0.13)
                        : hover.isHovered || configuration.isPressed ? SettingsTheme.controlHover : SettingsTheme.control,
                        in: shape)
            .overlay {
                if outlined || contrast == .increased {
                    shape.strokeBorder(outlined ? SettingsTheme.accent.opacity(0.30) : Color.primary.opacity(0.4), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(shape)
            .onHover { hover.isHovered = $0 }
            .fixedSize()
    }
}

/// Hover is view-local state. It lives in an object because the local swiftc build
/// does not load SwiftUI's State macro.
@MainActor
final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// A menu that looks like the push buttons: the current choice and a small chevron.
struct SettingsMenu<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.title ?? "")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(SettingsButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
    }
}

/// A row of small borderless choices; the selected one sits on a filled tile.
struct SettingsChoiceTiles<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(title: String, value: Value, help: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(selected ? SettingsMetrics.bodyEmphasis : SettingsMetrics.body)
                        .foregroundStyle(selected ? SettingsTheme.accent : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(minWidth: SettingsMetrics.controlHeight, minHeight: SettingsMetrics.controlHeight)
                        .background(selected ? SettingsTheme.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityLabel(option.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(SettingsTheme.control.opacity(0.5), in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The shortcut as one button: click to record a new one.
struct ShortcutButton: View {
    let shortcut: KeyShortcut
    let isRecording: Bool
    let registered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isRecording ? "Press keys…" : shortcut.keycaps.joined(separator: " "))
                .foregroundStyle(isRecording ? .secondary : .primary)
                .opacity(registered || isRecording ? 1 : 0.45)
        }
        .buttonStyle(SettingsButtonStyle())
        .accessibilityLabel("Open Dropy shortcut")
        .accessibilityValue(isRecording ? "Recording" : shortcut.display)
        .accessibilityHint(isRecording ? "Press the new shortcut, or Esc to cancel." : "Records a new shortcut.")
        .help(isRecording ? "Press the new shortcut. Esc cancels." : "Click to record a new shortcut")
    }
}

/// Visual choices share the same schematic screen, type and selection treatment.
struct OverlaySizeTiles: View {
    @Binding var selection: SizePreset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(SizePreset.allCases, id: \.self) { preset in option(preset).frame(minWidth: 108) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(SizePreset.allCases, id: \.self) { preset in option(preset) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overlay size")
    }

    private func option(_ preset: SizePreset) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = preset }
        } label: {
            SettingsVisualChoice(title: preset.title, subtitle: dimensions(preset), selected: selection == preset) {
                WorkspaceIllustration(preset: preset)
            }
        }
        .buttonStyle(SettingsVisualChoiceStyle())
        .accessibilityLabel(preset.title)
        .accessibilityValue(dimensions(preset))
        .accessibilityAddTraits(selection == preset ? .isSelected : [])
    }

    private func dimensions(_ preset: SizePreset) -> String {
        if preset == .nativeSize { return "Window size" }
        let size = preset.dimensions
        return "\(Int(size.width)) × \(Int(size.height))"
    }
}

struct OverlayPositionTiles: View {
    @Binding var selection: OverlayPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(OverlayPosition.allCases, id: \.self) { position in option(position).frame(minWidth: 100) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(OverlayPosition.allCases, id: \.self) { position in option(position) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open from")
    }

    private func option(_ position: OverlayPosition) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = position }
        } label: {
            SettingsVisualChoice(title: position.title, selected: selection == position) {
                WorkspaceIllustration(position: position)
            }
        }
        .buttonStyle(SettingsVisualChoiceStyle())
        .accessibilityLabel(position.title)
        .accessibilityAddTraits(selection == position ? .isSelected : [])
    }
}

struct SettingsVisualChoice<Artwork: View>: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    @ViewBuilder var artwork: Artwork
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artwork
                .aspectRatio(1.85, contentMode: .fit)
                .opacity(selected ? 1 : 0.65)
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(SettingsTheme.accent)
                }
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 26, alignment: .topLeading)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? SettingsTheme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? SettingsTheme.accent.opacity(0.35)
                              : Color.primary.opacity(contrast == .increased ? 0.35 : 0.075), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SettingsVisualChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsVisualChoiceBody(configuration: configuration)
    }
}

private struct SettingsVisualChoiceBody: View {
    let configuration: ButtonStyleConfiguration
    @StateObject private var hover = HoverState()

    var body: some View {
        configuration.label
            .background(hover.isHovered ? SettingsTheme.control : .clear, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hover.isHovered = $0 }
    }
}
