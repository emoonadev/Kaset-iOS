import SwiftUI

/// Debug and diagnostics tools, kept apart from the everyday preferences in `SettingsView`.
struct DeveloperSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @AppStorage("nativeNowPlaying") private var nativeNowPlaying = true
    @AppStorage("settings.handlePhoneCalls") private var handlePhoneCalls = true

    var body: some View {
        Form {
            Section {
                Toggle("Native Now Playing card", isOn: self.$nativeNowPlaying)
                #if os(iOS)
                Toggle("Pause for phone calls (relaunch)", isOn: self.$handlePhoneCalls)
                #endif
            } header: {
                Text("Behavior")
            }

            Section("Diagnostics") {
                NavigationLink {
                    PlayerHealthView(player: self.environment.player)
                } label: {
                    let failing = self.environment.player.healthReport?.failing.count ?? 0
                    LabeledContent("Player health") {
                        if failing > 0 {
                            Text("\(failing) failing").foregroundStyle(.red)
                        }
                    }
                }
                Button("Inspect queue (log)") { self.environment.player.inspectQueue() }
                Button("Inspect buffer (log)") { self.environment.player.inspectBuffer() }
                NavigationLink("Playback debug") { PlaybackDebugView(player: self.environment.player) }
                NavigationLink("API debug") { APIDebugView(client: self.environment.client, player: self.environment.player) }
            }
        }
        .navigationTitle("Developer")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}
