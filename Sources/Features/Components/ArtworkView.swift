import SwiftUI

/// Remote artwork with a neutral placeholder.
struct ArtworkView: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: self.url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            default:
                Rectangle().fill(.quaternary).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
    }
}
