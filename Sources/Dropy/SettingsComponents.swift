import AppKit
import SwiftUI
import DropyCore

/// Colors for the settings window. A flat neutral gray fills the content column and
/// the sidebar is Liquid Glass; every surface on top is a translucent tint of the label
/// color, so light, dark and increased contrast follow from the system appearance.
enum SettingsTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.94, green: 0.36, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.88, green: 0.27, blue: 0.29, alpha: 1)
    })

    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.155, green: 0.155, blue: 0.162, alpha: 1)
            : NSColor(srgbRed: 0.940, green: 0.940, blue: 0.945, alpha: 1)
    })

    /// The sidebar when Reduce Transparency replaces its glass: one step lighter than
    /// the window in dark mode and one step darker in light mode.
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.190, green: 0.190, blue: 0.198, alpha: 1)
            : NSColor(srgbRed: 0.905, green: 0.905, blue: 0.912, alpha: 1)
    })

    static let badge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.66, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.42, blue: 0.90, alpha: 1)
    })

    static let card = Color.primary.opacity(0.045)
    static let separator = Color.primary.opacity(0.08)
    static let control = Color.primary.opacity(0.08)
    static let controlHover = Color.primary.opacity(0.13)
    static let selection = Color.primary.opacity(0.08)
    static let iconTile = Color(white: 0.30)
}

/// The one type scale and set of dimensions every settings view draws from, so the
/// sidebar, cards, rows and controls line up with each other.
enum SettingsMetrics {
    // Type: macOS's 13-point body with an 11-point secondary line.
    static let body = Font.system(size: 13)
    static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    static let header = Font.system(size: 13, weight: .semibold)
    static let detail = Font.system(size: 11)
    static let badge = Font.system(size: 10, weight: .medium)

    // Controls: every button, menu and choice is the same height and corner.
    static let controlHeight: CGFloat = 24
    static let controlRadius: CGFloat = 6
    static let controlSpacing: CGFloat = 8

    // Cards and rows.
    static let cardRadius: CGFloat = 12
    static let cardSpacing: CGFloat = 20
    static let rowHeight: CGFloat = 40
    static let rowInset: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 8

    // Window layout.
    static let titleBarHeight: CGFloat = 52
    static let pageInset: CGFloat = 20
    static let iconSize: CGFloat = 20

    // Sidebar.
    static let sidebarInset: CGFloat = 10
    static let sidebarRowHeight: CGFloat = 28
    static let sidebarWidth: ClosedRange<CGFloat> = 180...320
    static let sidebarDefaultWidth: CGFloat = 220
}

/// The sidebar's Liquid Glass under a gray layer, so the desktop is only a faint hint.
/// The window is transparent behind the sidebar, so the glass refracts whatever is
/// behind it. Before macOS 26 it falls back to the frosted sidebar material; with
/// Reduce Transparency it is a solid surface.
struct SettingsSidebarGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if reduceTransparency {
            SettingsTheme.sidebar
        } else {
            SidebarGlassView(dark: colorScheme == .dark)
                // The glass tint alone lets the wallpaper through almost unchanged;
                // this gray layer leaves only a faint hint of it.
                .overlay {
                    (colorScheme == .dark ? Color(white: 0.13).opacity(0.8) : Color(white: 0.93).opacity(0.75))
                        .allowsHitTesting(false)
                }
        }
    }
}

/// Frosted glass with a dark tint, so the desktop shows only as muted color.
private struct SidebarGlassView: NSViewRepresentable {
    let dark: Bool

    private var tint: NSColor {
        dark ? NSColor(white: 0.08, alpha: 0.42) : NSColor(white: 0.25, alpha: 0.14)
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // Regular glass frosts the desktop; clear glass showed too much of it.
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = tint
            return glass
        }
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = tint
        }
    }
}

/// A scrolling column of cards. Pages carry no header of their own: the selected
/// sidebar row already names the page.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                content
            }
            .padding(.horizontal, SettingsMetrics.pageInset)
            .padding(.bottom, SettingsMetrics.pageInset)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .toggleStyle(.switch)
        .tint(SettingsTheme.accent)
    }
}

/// A rounded group of rows divided by inset hairlines, with an optional title above
/// and an explanation below.
struct SettingsCard<Content: View>: View {
    var title: String?
    var badge: String?
    var footer: String?
    @ViewBuilder var content: Content

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
        .controlSize(.mini)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SettingsMetrics.controlSpacing) {
                Text(title).font(SettingsMetrics.body)
                if let badge { SettingsBadge(badge) }
            }
            if let detail {
                Text(detail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
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
            .foregroundStyle(isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
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
            .font(SettingsMetrics.body)
            .lineLimit(1)
            .padding(.horizontal, circular ? 0 : 10)
            .frame(minWidth: circular ? height : nil, minHeight: height)
            .background(hover.isHovered || configuration.isPressed ? SettingsTheme.controlHover : SettingsTheme.control,
                        in: shape)
            .overlay {
                if outlined || contrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(outlined ? 0.22 : 0.4), lineWidth: 1)
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
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(minWidth: SettingsMetrics.controlHeight, minHeight: SettingsMetrics.controlHeight)
                        .background(selected ? SettingsTheme.control : .clear,
                                    in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityLabel(option.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
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

/// The overlay size choices as artwork tiles. The selected tile is in color and its
/// caption sits on a capsule; the others are grayscale. Each tile shows a schematic
/// window at the preset's relative size, never real window contents.
struct OverlaySizeTiles: View {
    @Binding var selection: SizePreset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: SettingsMetrics.rowInset) {
            ForEach(SizePreset.allCases, id: \.self) { preset in
                let selected = selection == preset
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = preset }
                } label: {
                    VStack(spacing: SettingsMetrics.controlSpacing) {
                        SizeArtwork(preset: preset, selected: selected)
                        Text(preset.title)
                            .font(selected ? SettingsMetrics.bodyEmphasis : SettingsMetrics.body)
                            .padding(.horizontal, 10)
                            .frame(minHeight: SettingsMetrics.controlHeight)
                            .background(selected ? SettingsTheme.controlHover : .clear, in: Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overlay size")
    }
}

private struct SizeArtwork: View {
    let preset: SizePreset
    let selected: Bool

    /// Window size as a share of the tile.
    private var scale: CGSize {
        switch preset {
        case .compact: CGSize(width: 0.42, height: 0.36)
        case .medium: CGSize(width: 0.58, height: 0.5)
        case .wide: CGSize(width: 0.76, height: 0.62)
        case .nativeSize: CGSize(width: 0.5, height: 0.66)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .top) {
                TileWallpaper(selected: selected)
                // The notch the overlay grows from.
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                    .fill(.black.opacity(0.85))
                    .frame(width: size.width * 0.24, height: 8)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color(red: 0.12, green: 0.10, blue: 0.36).opacity(0.85) : .black.opacity(0.55))
                    .overlay(alignment: .topLeading) {
                        Circle().fill(.white.opacity(0.35)).frame(width: 5, height: 5).padding(6)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Capsule().fill(.white.opacity(selected ? 0.22 : 0.15))
                            .frame(width: size.width * scale.width * 0.22, height: 5).padding(6)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                    .frame(width: size.width * scale.width, height: size.height * scale.height)
                    .padding(.top, 8)
            }
        }
        .aspectRatio(1.7, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius - 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius - 2, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.18 : 0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// The desktop picture behind the overlay in Settings' size and position tiles.
private struct TileWallpaper: View {
    let selected: Bool

    var body: some View {
        if selected {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.62), Color(red: 0.36, green: 0.30, blue: 0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 0.55, green: 0.40, blue: 1).opacity(0.9), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 120)
                RadialGradient(colors: [Color(red: 0.20, green: 0.55, blue: 1).opacity(0.8), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 110)
                RadialGradient(colors: [Color(red: 0.05, green: 0.04, blue: 0.30).opacity(0.9), .clear],
                               center: UnitPoint(x: 0.45, y: 0.85), startRadius: 0, endRadius: 70)
            }
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(white: 0.55).opacity(0.8), .clear],
                               center: UnitPoint(x: 0.85, y: 0.15), startRadius: 0, endRadius: 90)
                RadialGradient(colors: [Color(white: 0.05).opacity(0.9), .clear],
                               center: UnitPoint(x: 0.3, y: 0.8), startRadius: 0, endRadius: 80)
            }
        }
    }
}

/// Where the overlay opens from: a tile per position, each drawing the overlay's real
/// outline at that place on a small screen.
struct OverlayPositionTiles: View {
    @Binding var selection: OverlayPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: SettingsMetrics.rowInset) {
            ForEach(OverlayPosition.allCases, id: \.self) { position in
                let selected = selection == position
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = position }
                } label: {
                    VStack(spacing: SettingsMetrics.controlSpacing) {
                        PositionArtwork(position: position, selected: selected)
                        Text(position.title)
                            .font(selected ? SettingsMetrics.bodyEmphasis : SettingsMetrics.body)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 8)
                            .frame(minHeight: SettingsMetrics.controlHeight)
                            .background(selected ? SettingsTheme.controlHover : .clear, in: Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(position.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open from")
    }
}

private struct PositionArtwork: View {
    let position: OverlayPosition
    let selected: Bool

    var body: some View {
        ZStack {
            TileWallpaper(selected: selected)
            Canvas { context, size in
                let screen = CGRect(origin: .zero, size: size)
                let body = position.body(size: CGSize(width: size.width * 0.46, height: size.height * 0.5),
                                         screen: screen, visible: screen)
                let shape = NotchShape(body: body, bottomRadius: 5, earRadius: 4, position: position)
                // NotchShape draws with the origin at the bottom left; Canvas at the top left.
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                context.fill(Path(shape.fillPath).applying(flip),
                             with: .color(selected ? Color(red: 0.05, green: 0.04, blue: 0.16) : .black.opacity(0.85)))
                context.stroke(Path(shape.strokePath).applying(flip), with: .color(.white.opacity(0.14)), lineWidth: 0.5)
            }
        }
        .aspectRatio(1.6, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius - 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius - 2, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.18 : 0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
