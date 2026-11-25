import SwiftUI

/// The Settings window (⌘,), laid out as macOS preferences: a toolbar of tabs, each a short
/// grouped form, instead of the single long form of the iOS sheet. The sections are the ones
/// `SettingsView` uses on iOS.
struct MacSettingsView: View {
    private enum Pane: Hashable {
        case general, playback, accounts, recap, developer
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane = .general

    var body: some View {
        TabView(selection: self.$pane) {
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                Self.form {
                    ContentLanguageSettingsSection()
                    TrackNotificationsSettingsSection()
                    NewReleasesSettingsSection()
                }
            }
            Tab("Playback", systemImage: "play.circle", value: Pane.playback) {
                Self.form { PlaybackSettingsSections() }
            }
            Tab("Accounts", systemImage: "person.crop.circle", value: Pane.accounts) {
                Self.form { AccountSettingsSections { self.dismiss() } }
            }
            Tab("Recap", systemImage: "chart.bar", value: Pane.recap) {
                Self.form { RecapSettingsSection() }
            }
            Tab("Developer", systemImage: "hammer", value: Pane.developer) {
                // The diagnostics push detail pages.
                NavigationStack { DeveloperSettingsView() }
            }
        }
        .frame(width: 560, height: 520)
    }

    private static func form(@ViewBuilder content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
    }
}
