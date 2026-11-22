import SwiftUI

#if os(iOS)
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformView = UIView
#else
import AppKit

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformView = NSView

extension Image {
    /// `Image(uiImage:)` spelling on macOS, so shared views keep one call site.
    init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}
#endif

extension ToolbarItemPlacement {
    /// Top-right of the navigation bar on iOS, the window toolbar's trailing side on macOS.
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}

extension View {
    /// Small inline title on iOS; macOS titles always live in the window toolbar.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Identifiers and codes: no autocorrection or capitalization.
    func plainTextInput() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// macOS sheets size to their content, and a `NavigationStack` + `List` has none: give them
    /// a real window size. No change on iOS.
    func macSheetFrame(width: CGFloat = 560, height: CGFloat = 680) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    /// iOS sheets get half / full detents; macOS sheets get a usable fixed size instead.
    func adaptiveSheetSize(width: CGFloat = 480, height: CGFloat = 560) -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
        #else
        self.frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #endif
    }
}

/// Small platform switches for code shared by the iOS and macOS apps.
enum Platform {
    /// Application Support for the app's own files. On iOS the container is the app's; the macOS
    /// app is not sandboxed, so it gets a folder named after its bundle id (files written by
    /// earlier builds at the top of Application Support are moved there).
    static func appSupportFile(_ name: String) -> URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        let folder = root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.emoona.kaset.mac", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let legacy = root.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: url)
        }
        return url
        #else
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
        #endif
    }

    /// Where the debug log lives: Documents on iOS (Files app), ~/Library/Logs/Kaset on macOS.
    static var logFolder: URL {
        #if os(macOS)
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Kaset", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
