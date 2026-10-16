import Foundation

/// Which language the app's own words are read in: whatever macOS has chosen,
/// or one the user has pinned here. Two languages ship — English and
/// Simplified Chinese — and a pinned choice applies at once, because every
/// string the app shows goes through `L`, and `L` asks here first.
enum Localization {
    /// A choice, not a language: `system` is the refusal to choose, leaving
    /// the answer to the same place that already knows the time of day.
    enum Language: String, CaseIterable, Identifiable {
        case system, zhHans = "zh-Hans", english = "en"

        var id: String { rawValue }
    }

    static let defaultsKey = "appLanguage"

    /// Posted when the user pins a language. The settings window rebuilds
    /// itself on it; the menu rebuilds every time it opens; the line's words
    /// catch up the next time its views redraw.
    static let changedNotification = Notification.Name("appLanguageChanged")

    static var language: Language {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let stored = Language(rawValue: raw) else { return .system }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    /// The bundle one language's strings live in, found once and kept —
    /// `L` runs on every draw of every card, and a path search per call
    /// would be paying rent on a door nobody walks through.
    private static var bundles: [String: Bundle] = [:]

    private static func bundle(_ name: String) -> Bundle? {
        if let kept = bundles[name] { return kept }
        guard let path = Bundle.main.path(forResource: name, ofType: "lproj"),
              let made = Bundle(path: path) else { return nil }
        bundles[name] = made
        return made
    }

    /// The words for one English key, in the language the user has chosen.
    /// The keys are the English text, so a key a language has not translated
    /// answers in English by itself.
    static func string(_ english: String) -> String {
        switch language {
        case .system:
            NSLocalizedString(english, comment: "")
        case .zhHans:
            bundle("zh-Hans")?.localizedString(forKey: english, value: english, table: nil) ?? english
        case .english:
            bundle("en")?.localizedString(forKey: english, value: english, table: nil) ?? english
        }
    }
}

/// Looks up text in `Resources/<language>.lproj/Localizable.strings`, keyed by
/// the English text itself. The language is the user's whole preferred list,
/// unless they have pinned one in the settings — then it is that one, read
/// straight from its `.lproj` bundle rather than from whatever macOS picked.
///
/// The folders are copied into the app by `scripts/build-app.sh`. Running the
/// bare binary, outside the app, shows English.
func L(_ english: String) -> String {
    Localization.string(english)
}
