import SwiftUI

/// Account button shown in every tab's navigation bar; presents the settings sheet.
/// Shows the user's avatar when signed in, a person glyph otherwise.
struct SettingsToolbarButton: ToolbarContent {
    var body: some ToolbarContent {
        // macOS: the profile sits at the bottom of the sidebar and Settings is ⌘,.
        if !Platform.isMac {
            ToolbarItem(placement: .trailingBar) {
                SettingsSheetButton()
            }
        }
    }
}

private struct SettingsSheetButton: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = false

    private var isSignedIn: Bool { self.environment.auth.state == .signedIn }

    var body: some View {
        // Signed in: opens Settings. Guest: tapping signs in, long press offers Settings.
        Menu {
            Button("Settings", systemImage: "gearshape") { self.isPresented = true }
        } label: {
            self.label
        } primaryAction: {
            if self.isSignedIn {
                self.isPresented = true
            } else {
                self.environment.isLoginPresented = true
            }
        }
        .neutralMenuTint()
        .accessibilityLabel(self.isSignedIn ? "Settings" : "Sign in")
        .sheet(isPresented: self.$isPresented) { SettingsView() }
    }

    @ViewBuilder
    private var label: some View {
        Group {
            if let url = self.environment.accountAvatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
    }
}
