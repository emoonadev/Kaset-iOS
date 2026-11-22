import SwiftUI

/// Sidebar of the main window, laid out like Kaset for macOS (and Apple Music): Search and Home,
/// then Discover, Collection and the user's playlists, with the profile at the bottom.
struct MacSidebar: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MacShell.self) private var shell

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistTitle = ""
    @State private var isHoveringPlaylistsHeader = false

    private var isSignedIn: Bool { self.environment.auth.state == .signedIn }

    var body: some View {
        List {
            Section {
                self.row(.search)
                self.row(.home)
            }

            Section("Discover") {
                self.row(.explore)
                self.row(.charts)
                self.row(.moodsAndGenres)
                self.row(.newReleases)
            }

            if self.isSignedIn {
                Section("Collection") {
                    self.row(.library)
                    self.row(.likedMusic)
                    self.row(.history)
                    self.row(.recap)
                }

                Section {
                    ForEach(self.shell.playlists) { playlist in
                        self.row(.playlist(id: playlist.id, title: playlist.title))
                    }
                } header: {
                    self.playlistsHeader
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacSidebarFooter()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        .task(id: self.environment.auth.state) {
            await self.shell.loadPlaylists(signedIn: self.isSignedIn)
        }
        .onChange(of: self.environment.libraryRevision) {
            Task { await self.shell.loadPlaylists(signedIn: self.isSignedIn) }
        }
        .alert("New Playlist", isPresented: self.$isCreatingPlaylist) {
            TextField("Title", text: self.$newPlaylistTitle)
            Button("Create") { self.createPlaylist() }
            Button("Cancel", role: .cancel) { self.newPlaylistTitle = "" }
        }
    }

    private func row(_ item: MacSidebarItem) -> some View {
        MacSidebarRow(
            title: item.title,
            systemImage: item.systemImage,
            isSelected: self.shell.selection == item
        ) {
            self.shell.select(item)
        }
    }

    /// "Playlists" with a + that shows on hover, as in Kaset for macOS.
    private var playlistsHeader: some View {
        HStack {
            Text("Playlists")
            Spacer()
            Button {
                self.isCreatingPlaylist = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(self.isHoveringPlaylistsHeader ? 1 : 0)
            .padding(.trailing, 8)
            .help("New Playlist")
            .accessibilityLabel("New Playlist")
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { self.isHoveringPlaylistsHeader = hovering }
        }
    }

    private func createPlaylist() {
        let title = self.newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.newPlaylistTitle = ""
        guard !title.isEmpty else { return }
        Task {
            _ = try? await self.environment.client.createPlaylist(title: title)
            self.environment.libraryRevision += 1
        }
    }
}

/// A plain button row with Kaset's own selection fill and brand-coloured symbol, instead of
/// the source list's accent selection (which changes with focus).
struct MacSidebarRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Label {
                Text(self.title)
                    .lineLimit(1)
                    .fontWeight(self.isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: self.systemImage)
                    .foregroundStyle(Color.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowBackground(self.selectionBackground)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if self.isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
    }
}

/// Profile at the bottom of the sidebar: avatar and name with an account menu, or Sign in.
private struct MacSidebarFooter: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MacShell.self) private var shell
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                switch self.environment.auth.state {
                case .signedIn:
                    self.profileMenu
                case .signedOut:
                    Button {
                        self.environment.isLoginPresented = true
                    } label: {
                        Label("Sign in", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                case .unknown:
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var profileMenu: some View {
        Menu {
            let registry = self.environment.accounts
            ForEach(registry.accounts) { account in
                Button {
                    guard account.id != registry.activeID else { return }
                    Task {
                        await self.environment.switchGoogleAccount(to: account.id)
                        self.shell.resetForSignOut()
                    }
                } label: {
                    if account.id == registry.activeID {
                        Label(account.name ?? String(localized: "Google account"), systemImage: "checkmark")
                    } else {
                        Text(account.name ?? String(localized: "Google account"))
                    }
                }
            }
            Button("Add Account…") { self.environment.addAccount() }
            Divider()
            Button("Settings…") { self.openSettings() }
            Divider()
            Button("Sign Out") {
                Task {
                    await self.environment.signOut()
                    self.shell.resetForSignOut()
                }
            }
        } label: {
            HStack(spacing: 8) {
                AsyncImage(url: self.environment.accountAvatarURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                Text(self.environment.accountName ?? String(localized: "Account"))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}
