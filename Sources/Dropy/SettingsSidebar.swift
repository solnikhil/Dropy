import AppKit
import SwiftUI

/// The navigation column: search, then one row per page, on an opaque surface. Only the
/// selected row has a fill, and that fill moves between rows as one matched shape.
/// Native buttons keep focus and keyboard use.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel
    @Namespace private var selectionAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's real AppKit traffic lights sit in the title bar area above.
            Color.clear.frame(height: SettingsMetrics.titleBarHeight).accessibilityHidden(true)

            searchField
                .padding(.horizontal, SettingsMetrics.sidebarInset)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(SettingsPane.allCases) { pane in row(pane) }
                }
                .padding(.horizontal, SettingsMetrics.sidebarInset)
                .padding(.bottom, SettingsMetrics.sidebarInset)
            }
            .scrollIndicators(.never)
            .onMoveCommand { direction in
                guard let index = SettingsPane.allCases.firstIndex(of: model.pane) else { return }
                switch direction {
                case .up: select(SettingsPane.allCases[max(0, index - 1)])
                case .down: select(SettingsPane.allCases[min(SettingsPane.allCases.count - 1, index + 1)])
                default: break
                }
            }

        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }

    private func row(_ pane: SettingsPane) -> some View {
        let selected = model.pane == pane
        return Button {
            select(pane)
        } label: {
            HStack(spacing: SettingsMetrics.controlSpacing) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? SettingsTheme.accent : SettingsTheme.secondaryText)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(pane.title)
                    .font(selected ? SettingsMetrics.bodyEmphasis : SettingsMetrics.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pane == .updates, model.updater?.availableRelease != nil {
                    SettingsBadge("New")
                } else if let badge = pane.badge { SettingsBadge(badge) }
            }
            .padding(.horizontal, 10)
            .frame(height: SettingsMetrics.sidebarRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius))
        }
        .buttonStyle(SettingsNavigationStyle())
        .background {
            if selected {
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2, style: .continuous)
                    .fill(contrast == .increased ? Color.primary.opacity(0.18) : SettingsTheme.selection)
                    .matchedGeometryEffect(id: "selected-pane", in: selectionAnimation)
            }
        }
        .accessibilityLabel(pane.badge.map { "\(pane.title), \($0)" } ?? pane.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.secondaryText)
                .accessibilityHidden(true)
            TextField("Search", text: $model.settingsQuery)
                .textFieldStyle(.plain)
                .font(SettingsMetrics.body)
                .accessibilityLabel("Search settings")
                .accessibilityIdentifier("settings.search")
            if !model.settingsQuery.isEmpty {
                Button {
                    model.settingsQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(SettingsTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SettingsMetrics.sidebarRowHeight)
        .background(SettingsTheme.control, in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2,
                                                                 style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
            }
        }
    }

    private func select(_ pane: SettingsPane) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86)) {
            model.navigate(to: pane)
        }
    }
}

private struct SettingsNavigationStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsNavigationBody(configuration: configuration)
    }
}

private struct SettingsNavigationBody: View {
    let configuration: ButtonStyleConfiguration
    @StateObject private var hover = HoverState()

    var body: some View {
        configuration.label
            .background(hover.isHovered ? SettingsTheme.control : .clear,
                        in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hover.isHovered = $0 }
    }
}

/// The sidebar's trailing edge: a hairline with a wider invisible grip that resizes
/// the sidebar by dragging. Double-click restores the default width.
struct SettingsSidebarDivider: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Rectangle()
            .fill(SettingsTheme.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { model.resizeSidebar(by: $0.translation.width) }
                            .onEnded { _ in model.endSidebarResize() }
                    )
                    .onTapGesture(count: 2) { model.resetSidebarWidth() }
            }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(model.sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.setSidebarWidth(model.sidebarWidth + 20)
                case .decrement: model.setSidebarWidth(model.sidebarWidth - 20)
                @unknown default: break
                }
            }
    }
}

/// Back and forward through visited pages, drawn as one capsule in the title bar.
struct SettingsHistoryButtons: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .disabled(!model.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")
            .keyboardShortcut("[", modifiers: .command)
            Rectangle().fill(SettingsTheme.separator).frame(width: 1, height: 14)
            Button(action: model.goForward) {
                Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .disabled(!model.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")
            .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(HistoryButtonStyle())
        .font(.system(size: 13, weight: .medium))
        .background(SettingsTheme.control, in: Capsule())
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
            }
        }
    }
}

private struct HistoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HistoryButtonBody(configuration: configuration)
    }
}

private struct HistoryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
