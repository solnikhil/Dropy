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
                        Text(detail).font(SettingsMetrics.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if checker.isChecking { ProgressView().controlSize(.small) }
                            Button("Check for Updates") { checker.check() }
                                .buttonStyle(SettingsButtonStyle()).disabled(checker.isChecking)
                            if checker.availableRelease != nil {
                                Button("View Release") { checker.openRelease() }
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
                SettingsRow("Check Automatically", detail: "Checks published releases in the background each time Dropy starts.") {
                    SettingsValue("Every Startup")
                }
                SettingsRow("Last Successful Check") {
                    SettingsValue(checker.lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet checked")
                }
                SettingsRow("Release Source", detail: "GitHub Releases") { SettingsValue(checker.repository) }
            }
            if let release = checker.availableRelease, !release.notes.isEmpty {
                SettingsCard {
                    SettingsExplanation(title: "Release Notes", text: release.notes)
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
        case .noReleases: "No Stable Release Published"
        case .unavailable: "Unable to Check for Updates"
        }
    }
    private var detail: String {
        switch checker.state {
        case .idle: "Check for a newer published version of Dropy."
        case .checking: "Contacting the release source."
        case .current: "No newer stable version is available for this installation."
        case .available: "Installed version: \(checker.installedVersion). View the release to review changes and download it."
        case .noReleases: "The repository is available, but it has no published stable release."
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
