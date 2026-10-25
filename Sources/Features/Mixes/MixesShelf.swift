import SwiftUI

/// "My Mixes" on Home. Mixes are playlists, so their cards behave like any playlist cover:
/// tap opens the playlist, the play badge plays it. The last card creates a mix.
struct MixesShelf: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var editing: EditorTarget?
    @State private var failureMessage: String?

    private struct EditorTarget: Identifiable {
        let mix: ArtistMix?
        var id: String { self.mix?.id ?? "new" }
    }

    var body: some View {
        let library = self.environment.mixes
        VStack(alignment: .leading, spacing: 10) {
            Text("My Mixes")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    Button { self.startNewMix() } label: {
                        NewMixCard(isFirst: library.mixes.isEmpty, isCreating: library.isCreating)
                    }
                    .buttonStyle(.plain)
                    .disabled(library.isCreating)
                    ForEach(library.mixes) { mix in
                        let entity = Self.entity(for: mix)
                        NavigationLink(value: entity) {
                            MediaCard(entity: entity)
                                .overlay(alignment: .top) {
                                    if library.busyPlaylistId == mix.playlistId {
                                        ProgressView()
                                            .frame(width: 156, height: 156)
                                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .neutralMenuTint()
                        .contextMenu { self.menu(for: mix) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
        .sheet(item: self.$editing) { target in
            MixEditorView(mix: target.mix)
        }
        .alert("Mix", isPresented: Binding(
            get: { self.failureMessage != nil },
            set: { if !$0 { self.failureMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(self.failureMessage ?? "")
        }
        .task(id: self.environment.auth.state) {
            guard self.environment.auth.state == .signedIn else { return }
            await library.refresh(client: self.environment.client)
        }
    }

    @ViewBuilder
    private func menu(for mix: ArtistMix) -> some View {
        let library = self.environment.mixes
        Button("Play", systemImage: "play.fill") { library.play(mix, environment: self.environment) }
        Button("Regenerate", systemImage: "arrow.triangle.2.circlepath") {
            Task {
                do { try await library.regenerate(mix, environment: self.environment) } catch {
                    self.failureMessage = error.localizedDescription
                }
            }
        }
        Button("Edit Mix…", systemImage: "slider.horizontal.3") { self.editing = EditorTarget(mix: mix) }
    }

    private func startNewMix() {
        guard self.environment.auth.state == .signedIn else {
            self.environment.isLoginPresented = true
            return
        }
        self.editing = EditorTarget(mix: nil)
    }

    static func entity(for mix: ArtistMix) -> MediaEntity {
        MediaEntity(
            id: "mix-\(mix.id)", title: mix.displayName, subtitle: mix.artistSummary,
            thumbnailURL: mix.thumbnailURL, target: .playlist(id: mix.playlistId ?? ""), isCircular: false
        )
    }
}

/// Dashed square with a plus; doubles as the explanation when there are no mixes yet.
private struct NewMixCard: View {
    let isFirst: Bool
    let isCreating: Bool
    private let width: CGFloat = 156

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .frame(width: self.width, height: self.width)
                .overlay {
                    if self.isCreating {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color.brand)
                    }
                }
            Text("New Mix")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
            Text(self.isCreating ? "Creating…" : (self.isFirst ? "Pick your artists" : "Another set of artists"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Creates a playlist from artists you pick")
    }
}
