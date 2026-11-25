import SwiftUI

/// Sizes that differ between the phone and the Mac window: the Mac shows more, smaller-looking
/// content with roomier margins, like Kaset for macOS.
enum AdaptiveLayout {
    /// Width of an artwork card in a horizontal shelf.
    static let cardWidth: CGFloat = Platform.isMac ? 176 : 156
    /// Leading / trailing margin of shelves and sections.
    static let horizontalPadding: CGFloat = Platform.isMac ? 28 : 20
    /// Minimum width of a mood / genre chip.
    static let chipMinimumWidth: CGFloat = Platform.isMac ? 160 : 92
    /// Minimum column width of artwork grids (See all, Library).
    static let gridMinimum: CGFloat = Platform.isMac ? 176 : 150
    /// Artwork in a track row.
    static let trackArtwork: CGFloat = Platform.isMac ? 40 : 52
    /// Height of the primary / secondary header actions.
    static let actionHeight: CGFloat = Platform.isMac ? 34 : 48
    /// Spacing between cards in a shelf.
    static let cardSpacing: CGFloat = Platform.isMac ? 18 : 16
}
