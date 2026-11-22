import SwiftUI

/// Header actions on detail screens (playlist, album, artist).
///
/// Convention: one filled primary action (Play), a quiet secondary next to it (Shuffle, Mix),
/// both full-width, 48 pt tall, same corner radius. Anything else (library, follow, share)
/// goes in the navigation bar, where iOS users look for it.
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Platform.isMac ? .body.weight(.semibold) : .headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: AdaptiveLayout.actionHeight)
            .background(Color.brand.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Platform.isMac ? .body.weight(.semibold) : .headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: AdaptiveLayout.actionHeight)
            .background(Color(.tertiarySystemFill).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
