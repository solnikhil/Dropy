import SwiftUI

struct UpdatesSettingsPage: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        SettingsPage {
            SettingsCard {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .light)).foregroundStyle(SettingsTheme.accent)
                        .frame(width: 48, height: 48)
                        .background(SettingsTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Text(detail).font(SettingsMetrics.body).foregroundStyle(SettingsTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if checker.isChecking { ProgressView().controlSize(.small) }
                            Button("Check for Updates") { checker.check() }
                                .buttonStyle(SettingsButtonStyle()).disabled(!checker.canCheck)
                            if checker.availableRelease != nil {
                                Button("Install Update…") { checker.installUpdate() }
                                    .buttonStyle(SettingsButtonStyle(outlined: true))
                            }
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            SettingsCard("Update Checks") {
                SettingsRow("Installed Version") { SettingsValue(checker.installedVersion) }
                SettingsToggleRow("Check Automatically", detail: "Check on startup and periodically in the background.",
                    isOn: Binding(get: { checker.automaticallyChecks }, set: { checker.setAutomaticChecks($0) }))
                    .disabled(!checker.isConfigured)
                SettingsToggleRow("Download Updates Automatically", detail: "Download signed updates and install when Dropy quits. You can also install and relaunch immediately.",
                    isOn: Binding(get: { checker.automaticallyDownloads }, set: { checker.setAutomaticDownloads($0) }))
                    .disabled(!checker.allowsAutomaticDownloads)
                SettingsRow("Last Check") {
                    SettingsValue(checker.lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet checked")
                }
            }
        }
    }

    private var title: String {
        switch checker.state {
        case .idle: "Software Updates"
        case .checking: "Checking for Updates…"
        case .current: "Dropy Is Up to Date"
        case .available(let release): "Dropy \(release.version) Is Available"
        case .unavailable: "Unable to Check for Updates"
        }
    }
    private var detail: String {
        switch checker.state {
        case .idle: "Check for a newer published version of Dropy."
        case .checking: "Contacting the release source."
        case .current: "No newer stable version is available for this installation."
        case .available: "Installed version: \(checker.installedVersion). Install the signed update and relaunch Dropy."
        case .unavailable(let message): message
        }
    }
    private var symbol: String {
        switch checker.state {
        case .current: "checkmark.circle"
        case .available: "arrow.down.circle"
        case .unavailable: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        default: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}
