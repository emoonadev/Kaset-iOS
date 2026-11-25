import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Languages the YouTube Music API can be asked for (`hl`). Raw value is the stored setting.
enum ContentLanguage: String, CaseIterable, Identifiable {
    case system, en, fr, es, de, it, pt, ja, ko

    var id: String { self.rawValue }
    static let storageKey = "settings.contentLanguage"

    static var current: ContentLanguage {
        UserDefaults.standard.string(forKey: self.storageKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .en: "English"
        case .fr: "Français"
        case .es: "Español"
        case .de: "Deutsch"
        case .it: "Italiano"
        case .pt: "Português"
        case .ja: "日本語"
        case .ko: "한국어"
        }
    }

    var apiCode: String {
        if self == .system {
            let system = Locale.current.language.languageCode?.identifier ?? "en"
            return Self.allCases.contains { $0.rawValue == system } ? system : "en"
        }
        return self.rawValue
    }
}

/// Light haptics for transport buttons; off switch in Settings.
@MainActor
enum Haptics {
    static let storageKey = "settings.haptics"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: self.storageKey) as? Bool ?? true
    }

    static func tap() {
        guard self.isEnabled else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }
}
