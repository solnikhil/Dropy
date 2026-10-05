import AppKit
import SwiftUI

/// The persistent navigation rail shares a glass material with the detail surface.
/// A single matched selection shape moves between rows instead of six independent
/// highlights flashing on and off. Native buttons preserve focus and keyboard use.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    @ObservedObject var model: SettingsModel
    @Namespace private var selectionAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var selectionColor: Color {
        contrast == .increased ? Color.accentColor.opacity(0.32) : Color.accentColor.opacity(0.16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's real AppKit traffic lights sit above this reserved area.
            // Keeping them native preserves zoom, full screen, and accessibility.
            Color.clear.frame(height: 38).accessibilityHidden(true)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dropy").font(.system(size: 15, weight: .semibold))
                    Text("Settings").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 18)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 18)

            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        select(pane)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(selection == pane ? Color.accentColor : Color.secondary)
                                .frame(width: 23, height: 24)
                                .accessibilityHidden(true)
                            Text(pane.title)
                                .font(.system(size: 13, weight: selection == pane ? .semibold : .regular))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 40)
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selection == pane {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(selectionColor)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(contrast == .increased ? 0.8 : 0.14), lineWidth: 1)
                                }
                                .matchedGeometryEffect(id: "selected-pane", in: selectionAnimation)
                        }
                    }
                    .accessibilityAddTraits(selection == pane ? .isSelected : [])
                    .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
                }
            }
            .padding(.horizontal, 8)
            .onMoveCommand { direction in
                guard let index = SettingsPane.allCases.firstIndex(of: selection) else { return }
                switch direction {
                case .up: select(SettingsPane.allCases[max(0, index - 1)])
                case .down: select(SettingsPane.allCases[min(SettingsPane.allCases.count - 1, index + 1)])
                default: break
                }
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 12) {
                Divider().opacity(0.5)
                HStack(spacing: 6) {
                    Text("Open Dropy").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(model.preferences.shortcut.display)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(model.versionText).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(14)
        }
        .modifier(SettingsGlassSurface())
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $model.settingsQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("Search settings")
                .accessibilityIdentifier("settings.search")
            if !model.settingsQuery.isEmpty {
                Button {
                    model.settingsQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        }
    }

    private func select(_ pane: SettingsPane) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86)) {
            selection = pane
        }
        model.settingsQuery = ""
    }

}
