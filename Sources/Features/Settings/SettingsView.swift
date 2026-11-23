import SwiftUI

/// Account, playback and content preferences, plus diagnostics entry points.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @AppStorage(PlaybackAudioQuality.storageKey) private var audioQuality = PlaybackAudioQuality.auto.rawValue
    @AppStorage(ContentLanguage.storageKey) private var language = ContentLanguage.system.rawValue
    @AppStorage(Haptics.storageKey) private var haptics = true
    @AppStorage("nativeNowPlaying") private var nativeNowPlaying = true
    @AppStorage(AdSkip.storageKey) private var adAutoSkip = false
    @AppStorage(DataSaver.storageKey) private var dataSaver = true
    @AppStorage("settings.handlePhoneCalls") private var handlePhoneCalls = true
    @AppStorage(BufferPolicy.adaptiveQualityStorageKey) private var adaptiveQuality = true
    @AppStorage(BufferPolicy.extendedStorageKey) private var extendedBuffer = false
    @AppStorage(NewReleaseWatcher.notificationsStorageKey) private var newReleaseNotifications = true

    @State private var accounts: [UserAccount] = []
    @State private var isSwitching = false
    @State private var isPickingSyncFolder = false

    var body: some View {
        NavigationStack {
            Form {
                self.accountSection

                Section {
                    Picker("Audio quality", selection: self.$audioQuality) {
                        ForEach(PlaybackAudioQuality.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .onChange(of: self.audioQuality) { _, _ in self.environment.player.applyAudioQuality() }
                    #if os(iOS)
                    Toggle("Haptic feedback", isOn: self.$haptics)
                    #endif
                    Toggle("Skip ads automatically", isOn: self.$adAutoSkip)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Skipping ads is an opt-in and may go against YouTube's terms of service.")
                }
                .onChange(of: self.adAutoSkip) { _, _ in self.environment.player.applyAdSkipSetting() }

                Section {
                    Toggle("Save data on music videos", isOn: self.$dataSaver)
                        .onChange(of: self.dataSaver) { _, _ in self.environment.player.applyDataSaverSetting() }
                } footer: {
                    Text("Music videos play as their song version when YouTube Music has one (Premium), which can differ slightly from the video; other videos load at the lowest quality. The app never shows the video, so this only saves data.")
                }

                Section {
                    Toggle("Lower quality on a weak network", isOn: self.$adaptiveQuality)
                        .onChange(of: self.adaptiveQuality) { _, _ in self.environment.player.applyAudioQuality() }
                    Toggle("Longer buffer (experimental)", isOn: self.$extendedBuffer)
                        .onChange(of: self.extendedBuffer) { _, _ in self.environment.player.applyBufferSetting() }
                } header: {
                    Text("Bad network")
                } footer: {
                    Text("Low quality is used after the music cut out for lack of data, or in Low Data Mode, until you are back on Wi-Fi. The longer buffer asks the page to load up to 4 minutes of the current song ahead; it fully applies after relaunching the app.")
                }

                self.newReleasesSection

                self.recapSection

                Section {
                    Picker("Content language", selection: self.$language) {
                        ForEach(ContentLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .onChange(of: self.language) { _, _ in
                        self.environment.client.resetSessionState()
                    }
                } footer: {
                    Text("Changes the language of titles and shelves returned by YouTube Music.")
                }

                Section("Diagnostics") {
                    Toggle("Native Now Playing card", isOn: self.$nativeNowPlaying)
                    #if os(iOS)
                    Toggle("Pause for phone calls (relaunch)", isOn: self.$handlePhoneCalls)
                    #endif
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
            .navigationTitle("Settings")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { self.dismiss() } }
            }
            #else
            .formStyle(.grouped)
            #endif
            .task(id: AccountsLoadKey(state: self.environment.auth.state, revision: self.environment.accountRevision)) {
                await self.loadAccounts()
            }
        }
    }

    private var newReleasesSection: some View {
        let watcher = self.environment.newReleases
        return Section {
            Toggle("Notify me at 8:00", isOn: self.$newReleaseNotifications)
                .onChange(of: self.newReleaseNotifications) { _, isOn in
                    guard isOn else { return }
                    Task {
                        if await !watcher.requestNotificationPermission() { self.newReleaseNotifications = false }
                    }
                }
            Button {
                Task { await watcher.checkNow(client: self.environment.client, auth: self.environment.auth) }
            } label: {
                LabeledContent("Check now") {
                    if watcher.isChecking {
                        ProgressView()
                    } else if let last = watcher.state.lastCheck {
                        Text(last, format: .relative(presentation: .named))
                    }
                }
            }
            .disabled(watcher.isChecking || self.environment.auth.state != .signedIn)
            if let result = watcher.state.lastResult {
                if let failure = result.failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                } else {
                    Text("\(result.checked) of \(result.artists) artists checked · \(result.found) new · \(watcher.shelf.count) on Home")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("New releases")
        } footer: {
            Text("Albums and singles from the artists you follow and play the most show up on Home. The check runs each morning when iOS allows it (Background App Refresh must be on), otherwise when you open the app.")
        }
    }

    private var recapSection: some View {
        let listening = self.environment.listening
        return Section {
            if let folder = listening.syncFolderName {
                LabeledContent("Sync folder", value: folder)
                Button {
                    Task { await listening.sync() }
                } label: {
                    LabeledContent("Sync now") {
                        if listening.isSyncing {
                            ProgressView()
                        } else if let last = listening.lastSync {
                            Text(last, format: .relative(presentation: .named))
                        }
                    }
                }
                .disabled(listening.isSyncing)
                Button("Stop syncing", role: .destructive) { listening.stopSyncing() }
            } else {
                Button("Sync with iCloud Drive…") { self.isPickingSyncFolder = true }
            }
            if let error = listening.syncError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if let first = listening.plays.first {
                Text("\(listening.plays.count) plays since \(first.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Listening recap")
        } footer: {
            if let email = listening.accountEmail {
                Text("Plays are recorded on this device once a song has played for 30 seconds, separately for each account. To share them between devices, pick the same iCloud Drive folder on each one: the app keeps a file named “\(ListeningHistory.syncFileName(for: email))” in it for this account.")
            } else {
                Text("Plays are recorded on this device once a song has played for 30 seconds, separately for each account, while you are signed in. To share them between devices, pick the same iCloud Drive folder on each one.")
            }
        }
        .fileImporter(isPresented: self.$isPickingSyncFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(folder) = result else { return }
            Task { await listening.setSyncFolder(folder) }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        let registry = self.environment.accounts
        Section {
            if self.environment.auth.state == .unknown {
                ProgressView()
            }
            ForEach(registry.accounts) { account in
                Button {
                    let isActive = account.id == registry.activeID
                    if isActive, self.environment.auth.state == .signedOut {
                        self.dismiss()
                        self.environment.signInAgain()
                        return
                    }
                    guard !isActive else { return }
                    Task {
                        self.isSwitching = true
                        await self.environment.switchGoogleAccount(to: account.id)
                        self.isSwitching = false
                    }
                } label: {
                    AccountRow(
                        account: account,
                        isActive: account.id == registry.activeID,
                        isExpired: account.id == registry.activeID && self.environment.auth.state == .signedOut
                    )
                }
                .foregroundStyle(.primary)
                .disabled(self.isSwitching)
            }
            Button(registry.accounts.isEmpty ? "Sign in" : "Add account", systemImage: "plus.circle") {
                self.dismiss()
                self.environment.addAccount()
            }
            .disabled(self.isSwitching)
        } header: {
            Text("Accounts")
        } footer: {
            if registry.accounts.count > 1 {
                Text("Each account keeps its own session, library and history. Playback stops when you switch.")
            }
        }

        if self.environment.auth.state == .signedIn, self.accounts.count > 1 {
            Section("Channel") {
                ForEach(self.accounts) { account in
                    Button {
                        guard !account.isSelected else { return }
                        Task {
                            self.isSwitching = true
                            await self.environment.switchAccount(to: account)
                            self.isSwitching = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.name)
                                if let handle = account.handle {
                                    Text(handle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if account.isSelected { Image(systemName: "checkmark") }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(self.isSwitching)
                }
            }
        }

        if let active = registry.active {
            Section {
                Button(role: .destructive) {
                    Task {
                        self.isSwitching = true
                        await self.environment.signOut()
                        self.isSwitching = false
                        if self.environment.accounts.accounts.isEmpty { self.dismiss() }
                    }
                } label: {
                    if let name = active.name {
                        Text("Sign out of \(name)")
                    } else {
                        Text("Sign out")
                    }
                }
                .disabled(self.isSwitching)
            }
        }
    }

    private func loadAccounts() async {
        guard self.environment.auth.state == .signedIn else {
            self.accounts = []
            return
        }
        self.accounts = (try? await self.environment.client.fetchAccountsList().accounts) ?? []
    }
}

private struct AccountsLoadKey: Equatable {
    let state: AuthState
    let revision: Int
}

/// One Google account in the account list.
private struct AccountRow: View {
    let account: GoogleAccount
    let isActive: Bool
    let isExpired: Bool

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: self.account.avatarURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            VStack(alignment: .leading) {
                Text(self.account.name ?? String(localized: "Google account"))
                if self.isExpired {
                    Text("Signed out. Tap to sign in again.").font(.caption).foregroundStyle(.red)
                } else if let detail = self.account.email ?? self.account.handle {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if self.isActive { Image(systemName: "checkmark") }
        }
    }
}
