import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Which way the app dresses.
///
/// Three answers rather than two, because following the system is not the
/// same as choosing light — it is refusing to choose, and leaving that choice
/// to the one place that already knows about the time of day. An app that
/// only offers light and dark has quietly decided that the system setting is
/// not worth following.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L("Same as the system")
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }

    /// What the app wears, applied to the whole of it at once.
    ///
    /// On the application rather than on each window, because the line is
    /// three windows and a panel, and the settings window is a fourth: setting
    /// it in four places is four places to forget.
    ///
    /// `nil` is how AppKit spells "ask the system", which is what following
    /// it means — and it keeps following it after the system changes, which
    /// reading the current setting once and pinning it would not.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static let defaultsKey = "appAppearance"

    static var current: Appearance {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let stored = Appearance(rawValue: raw) else { return .system }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NSApp.appearance = newValue.nsAppearance
        }
    }

    /// Puts the stored choice back on at launch.
    static func restore() {
        NSApp.appearance = current.nsAppearance
    }
}

/// One language the 译 button can be pointed at.
///
/// The name is written in the language it names, and it is *short* on purpose:
/// this string is drawn inside a 26-point chip. `Locale.localizedString(forLanguageCode:)`
/// would answer "Chinese (Traditional)", which is a sentence, not a value on a
/// button — so the seven names are spelled out here, once, where they can be
/// looked at at the size they are actually drawn.
struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }
    var language: Locale.Language { Locale.Language(identifier: code) }
}

/// The languages this app offers, and no others.
///
/// A fixed list rather than everything the system knows: the `Translation`
/// framework can only reach a pair it has (or can download), and a menu of
/// ninety languages is a menu where the four a person uses are four rows among
/// eighty-six. These are the ones the capture bar has been asked for; adding one
/// is one line, and the button measures the widest name it is given.
enum TranslationCatalogue {
    static let all: [TranslationLanguage] = [
        TranslationLanguage(code: "zh-Hans", name: "简体中文"),
        TranslationLanguage(code: "zh-Hant", name: "繁體中文"),
        TranslationLanguage(code: "en", name: "English"),
        TranslationLanguage(code: "ja", name: "日本語"),
        TranslationLanguage(code: "ko", name: "한국어"),
        TranslationLanguage(code: "es", name: "Español"),
        TranslationLanguage(code: "fr", name: "Français"),
        TranslationLanguage(code: "de", name: "Deutsch"),
        TranslationLanguage(code: "pt", name: "Português"),
        TranslationLanguage(code: "ru", name: "Русский"),
    ]

    static func named(_ code: String) -> TranslationLanguage? {
        all.first { $0.code == code }
    }
}

/// Which languages the 译 button offers, and which of them it uses.
///
/// Two settings, not one. The list is the shortlist a person configured — the
/// capture bar's menu shows exactly those, in that order — and the current one
/// is what a press of `译` (or the `T` key) translates into. Keeping them apart
/// is what makes "press it and it just happens" possible without a menu.
///
/// The storage is a language code, so the old four-case enum had to be carried
/// across: a `TranslationTarget` written by the last build says `english`, and
/// losing that on update would silently change everyone's answer back to the
/// system language.
enum TranslationTargets {
    static let listKey = "translationTargets"
    /// The same key the old `TranslationTarget` wrote to, deliberately: one key
    /// for one question ("where should it land"), with the old values migrated
    /// on first read.
    static let currentKey = "translationTarget"

    /// Three directions that cover the ordinary cases on a Chinese Mac: English
    /// in, Chinese out, and Simplified ↔ Traditional, which is a translation
    /// that no engine will do for you.
    ///
    /// `zh-Hans` rather than `en` as the one in force, although the ask said
    /// "default to English": pressing `译` on English words and asking for
    /// English answers 「已经是这种语言了」 and nothing happens, which is a first
    /// impression that reads as a broken button. The language a person reads is
    /// the useful default; the ask's own example was "比如".
    static let fallback = ["zh-Hans", "zh-Hant", "en"]
    static let fallbackCurrent = "zh-Hans"

    private static let legacy: [String: String] = [
        "english": "en", "simplifiedChinese": "zh-Hans", "traditionalChinese": "zh-Hant",
    ]

    static var chosen: [String] {
        get {
            migrateOnce()
            let stored = UserDefaults.standard.stringArray(forKey: listKey) ?? []
            let known = stored.filter { TranslationCatalogue.named($0) != nil }
            return known.isEmpty ? fallback : known
        }
        set {
            var seen: [String] = []
            for code in newValue where TranslationCatalogue.named(code) != nil && !seen.contains(code) {
                seen.append(code)
            }
            // Kept in the catalogue's order rather than the order they were
            // ticked: the menu is read, not built, and a list that rearranges
            // itself as things are added is a list with no place to remember.
            let order = TranslationCatalogue.all.map(\.code)
            seen.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            UserDefaults.standard.set(seen.isEmpty ? fallback : seen, forKey: listKey)
            // The current one has to stay one of them: a button that says
            // "Español" while its menu no longer offers it is a button that
            // cannot be explained.
            if !seen.contains(current) {
                current = seen.first ?? fallbackCurrent
            }
        }
    }

    static var current: String {
        get {
            migrateOnce()
            guard let raw = UserDefaults.standard.string(forKey: currentKey) else { return fallbackCurrent }
            let code = legacy[raw] ?? raw
            if code == "system" { return systemLanguage }
            return TranslationCatalogue.named(code) == nil ? fallbackCurrent : code
        }
        set { UserDefaults.standard.set(newValue, forKey: currentKey) }
    }

    /// The language the interface is in, which is what the old `system` case
    /// meant. Read from the system's preferred languages rather than the app's,
    /// because the 译 button answers about the screen, not about the interface.
    private static var systemLanguage: String {
        let identifier = Locale.preferredLanguages.first ?? "en"
        if identifier.hasPrefix("zh") {
            return identifier.contains("Hant") || identifier.contains("TW")
                || identifier.contains("HK") ? "zh-Hant" : "zh-Hans"
        }
        return String(identifier.prefix(2))
    }

    /// Carries the old single-choice setting across, once.
    ///
    /// Done on read rather than at launch because there is no launch step this
    /// app is guaranteed to run before somebody opens a capture — and a migration
    /// that runs late is a migration that runs after the wrong answer has already
    /// been used.
    private static func migrateOnce() {
        let defaults = UserDefaults.standard
        guard defaults.stringArray(forKey: listKey) == nil,
              let raw = defaults.string(forKey: currentKey), let mapped = legacy[raw] else { return }
        defaults.set([mapped] + fallback.filter { $0 != mapped }, forKey: listKey)
        defaults.set(mapped, forKey: currentKey)
    }
}

/// The settings window: one window, six pages, and nothing else.
///
/// A window rather than more of the menu, because the menu is a list of
/// things to do and this is a place to decide — and because the list had
/// grown past what a menu should hold. What is left in the menu is what a
/// person reaches for mid-task; what is here is what they set once.
///
/// It is an ordinary window: titled, closable, and able to take the key in
/// the way any window does. The line's windows go out of their way not to
/// steal focus; a settings window that refused it could not be typed into.
@MainActor
final class SettingsController {
    static let shared = SettingsController()

    /// Read by the view to retitle the window when the language changes;
    /// only this controller ever hands the window in or out.
    private(set) var window: NSWindow?
    /// The line, so a paper chosen here is on the cards the moment it is
    /// chosen. Handed over at launch beside the note controller's, for the
    /// same reason: the settings write the choice the line re-reads.
    weak var line: Line?
    private init() {}

    func open() {
        if window == nil { window = makeWindow() }
        // A status-bar app is not the active app by definition, so a window
        // brought forward without this comes forward behind whatever the
        // user is working in.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingView(rootView: SettingsView(line: line))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindow.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = L("Settings")
        window.contentView = host
        window.isReleasedWhenClosed = false
        // The title bar lets the page's ground through: with the content
        // under it already, an opaque bar would draw the window's own grey
        // strip across the top, one shade apart from the page it sits on.
        window.titlebarAppearsTransparent = true
        // Centred once, when it is made. A settings window that reopened
        // wherever it was last dragged would be a window in a different place
        // every time, which is the opposite of what a settings window is.
        window.center()
        return window
    }
}

enum SettingsWindow {
    /// Wide enough that six tabs read without squeezing, and tall enough for
    /// the busiest page whole — no page may be cut off by the bottom edge: a
    /// setting the user has to scroll for is a setting the user does not find.
    ///
    /// 620 rather than 560 since the capture page took on the translation and
    /// editor cards (2026-11-03): with them the page ran 60 points past the old
    /// height and the last card sat below the fold — present, and unreachable.
    static let size = CGSize(width: 600, height: 620)
}

/// What the window is made of.
struct SettingsView: View {
    /// The line, handed down to the page that changes what it draws.
    let line: Line?

    /// Which page to open on. Only the layout harness passes anything: every
    /// other way in opens on the first one, and a settings window that
    /// remembered the last page would be a window with a memory nobody asked it
    /// to keep.
    init(line: Line?, section: Section = .general) {
        self.line = line
        _section = State(initialValue: section)
    }

    /// Read for the window's ground: white in light mode, the system grey in
    /// dark, where light's answer would glow.
    @Environment(\.colorScheme) private var colorScheme

    @State private var section: Section = .general
    /// Bumped when the user pins a language. An `.id` on the body makes
    /// SwiftUI rebuild the pages from nothing, so every string on them is
    /// asked of `L` again — a language change reads through the whole
    /// window instead of waiting for each view to redraw.
    @State private var languageToken = 0

    enum Section: String, CaseIterable, Identifiable {
        case general, invocation, capture, clipboard, keeping, permissions, about
        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: L("General")
            case .clipboard: L("Clipboard")
            case .invocation: L("Invocation")
            case .capture: L("Capture")
            case .keeping: L("Keeping")
            case .permissions: L("Permissions")
            case .about: L("About")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .clipboard: "doc.on.clipboard"
            case .invocation: "arrow.down.to.line"
            case .capture: "viewfinder"
            case .keeping: "clock.arrow.circlepath"
            case .permissions: "lock.shield"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Across the top rather than down the side. Five pages do not need
            // a sidebar — a sidebar for five things turns one window into two
            // and spends 170 points on it — and across the top the row is one
            // line of choices, which is what it is.
            //
            // The CDS segmented capsule rather than the filled accent bar the
            // tabs wore first: a 999px track with a clay pill that slides
            // between choices on the 120 ms spring. The bar answered "which
            // one am I on" with colour; the sliding pill answers it with
            // colour *and* gives the answer a direction — the eye follows the
            // pill from the choice it is leaving to the one it is making,
            // which is the one question a row of five never answers on its
            // own.
            HStack(spacing: 2) {
                ForEach(Section.allCases) { option in
                    tab(option)
                }
            }
            .padding(3)
            // No track fill of its own: the strip sits on the window's
            // material ground, the same surface the in-form page draws, so
            // the tab row and the page read as one continuous background
            // rather than a pill floating above them.
            .background(Capsule().fill(Color.clear))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch section {
                case .general: GeneralPage(line: line)
                case .clipboard: ClipboardPage(line: line)
                case .invocation: InvocationPage()
                case .capture: CapturePage()
                case .keeping: KeepingPage()
                case .permissions: PermissionsPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        // The warm ground for the whole window, tab strip included. Every page
        // hands its Form's grey back (`.scrollContentBackground(.hidden)`), so
        // this colour is the page floor as well: the white grouped cards float
        // on it and the strip above wears the same paper. The Flyring
        // arrangement, so the two halves of the window read as one ground.
        .background(CDS.ground)
        // Clay is the emphasis colour of every control in the window: the
        // switches, the pickers' highlights, the focus of the fields. One
        // tint here rather than one per control, because an accent asked for
        // five times is an accent that can be forgotten the sixth.
        .tint(CDS.clay)
        .id(languageToken)
        .onReceive(NotificationCenter.default.publisher(for: Localization.changedNotification)) { _ in
            languageToken += 1
            SettingsController.shared.window?.title = L("Settings")
        }
    }

    private func tab(_ option: Section) -> some View {
        let selected = section == option
        return Button {
            section = option
        } label: {
            HStack(spacing: 6) {
                Image(systemName: option.symbol)
                    .frame(width: 16)
                Text(option.label)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            // Ink on clay in the dark, white in the light: white on clay
            // in the dark glows less than it reads (see `CDS.label`).
            .foregroundStyle(selected ? CDS.label(onClayIn: colorScheme) : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                if selected {
                    // One capsule for the whole strip, moved by
                    // `matchedGeometryEffect`: the pill slides rather than
                    // appears, which is the 120 ms geometric bite.
                    Capsule()
                        .fill(CDS.clay)
                        .matchedGeometryEffect(id: "settings.tab.pill", in: pillSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(CDS.slideAnimation, value: section)
    }

    @Namespace private var pillSpace
}

// MARK: - General

/// The taste questions: how the app dresses, which words it speaks, whether
/// it opens at login, which way a swipe goes, whether it makes a sound. None
/// of them is a thing done to the line in a moment — they are answers given
/// once and kept — so this page is where they live, and the menu stays a menu
/// of things to do.
struct GeneralPage: View {
    let line: Line?

    @State private var chosen: Appearance = Appearance.current
    @State private var language: Localization.Language = Localization.language
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var panReversed = AppDelegate.panReversed
    @State private var sideButtonPaging = AppDelegate.sideButtonPaging
    @State private var soundOn: Bool

    init(line: Line?) {
        self.line = line
        _soundOn = State(initialValue: line?.soundOn ?? false)
    }

    var body: some View {
        Form {
            // The page's name, inside the first card as a plain headline row —
            // the Flyring house style: titles read as words, not as the small
            // grey caps a grouped header renders.
            Section {
                Text(L("Appearance & behaviour"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker(L("Appearance"), selection: $chosen) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
            .onChange(of: chosen) { _, option in
                Appearance.current = option
            }

            Section {
                // Language names are not translated: each is written in the
                // language it names, because a reader who cannot read the
                // current language has to be able to find their own anyway.
                Picker(L("Language"), selection: $language) {
                    Text(L("Same as the system")).tag(Localization.Language.system)
                    Text("简体中文").tag(Localization.Language.zhHans)
                    Text("English").tag(Localization.Language.english)
                }
                Text(L("Changes apply at once."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: language) { _, picked in
                Localization.language = picked
            }

            // The 译成 picker and the engine that answers it moved to the
            // Clipboard page, beside the key that chooses between the two
            // engines: a translation setting three cards away from the field
            // that decides who does the translating is a setting nobody finds.

            Section {
                Toggle(L("Open at login"), isOn: $atLogin)
            }

            Section {
                Toggle(L("Swipe the other way"), isOn: $panReversed)
                Toggle(L("Mouse side buttons page"), isOn: $sideButtonPaging)
                // Said plainly rather than left to be discovered: the two thumb
                // keys are also the two keys another app may have taken, and a
                // global shortcut registered by someone else cannot be taken
                // back from here. So this switch, once on, may well do nothing
                // — which is not a fault here but a fact about the system, and
                // the user is the one who knows whether their mouse has them.
                // Off by default for that reason: a feature that silently does
                // nothing is worse than one that is simply absent.
                if sideButtonPaging {
                    Text(L("Off by default. If another app has recorded these buttons as a global shortcut — Flyring does — both will answer at once, and that cannot be prevented from here. The wheel and the arrows page without this."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // What it does and what it leaves out, said together: a switch
            // that promises "shortcuts" and then shows letters on some
            // buttons but not on the four that use ⌘ reads as half done,
            // unless it says why first. The switch itself lives on the
            // Clipboard page now, next to the capture's other answers.

            Section {
                Toggle(L("Sounds"), isOn: $soundOn)
                    .disabled(line == nil)
                // The three events a line sounds, each with its own answer.
                // Shown only while sound is on at all — a picker under a
                // switch that silences everything reads as broken.
                if soundOn {
                    SoundPickerRow(label: L("Card arrives"), event: .hang, line: line)
                    SoundPickerRow(label: L("Card is taken down"), event: .remove, line: line)
                    SoundPickerRow(label: L("Reminder"), event: .reminder, line: line)
                }
            }


        }
        .formStyle(.grouped)
        // CDS / Flyring arrangement: hand the Form's own grey back, let the
        // window's warm ground (CDS.ground) show through, and the grouped
        // cards — the system's own white cards — float on that paper. The
        // tab strip above wears the same ground, so strip and page read as
        // one continuous background.
        .scrollContentBackground(.hidden)
        .onChange(of: atLogin) { _, _ in
            // Asked rather than assumed: the registration can refuse, and the
            // tick says what the system actually agreed to.
            AppDelegate.toggleLaunchAtLogin()
            atLogin = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: panReversed) { _, on in
            AppDelegate.panReversed = on
        }
        .onChange(of: sideButtonPaging) { _, on in
            AppDelegate.sideButtonPaging = on
        }
        .onChange(of: soundOn) { _, on in
            line?.soundOn = on
        }
    }
}

// MARK: - Clipboard

/// What a copy is allowed to become: formatted or plain, picture or file,
/// and the folders whose new pictures hang by themselves. Everything here
/// answers one question — how a copy becomes a card — which is why it is a
/// page of its own rather than rows folded into the general one: the general
/// page is what the app is, and this page is what a copy turns into.
struct ClipboardPage: View {
    let line: Line?

    @State private var copyFormatted = FormatCopy.isEnabled
    @State private var imageFilesAsPictures = ImageFileHanging.isEnabled
    @State private var imageFileLimitText = String(ImageFileHanging.limitMB)

    /// The typed limit, when it is one this app will honour: a whole number
    /// between one and 1024 megabytes. Anything else is a typing in progress,
    /// not an answer.
    private static func parsedLimit(_ text: String) -> Int? {
        guard let mb = Int(text.trimmingCharacters(in: .whitespaces)), (1...1024).contains(mb) else { return nil }
        return mb
    }

    /// Puts the field back to the limit in force, for an entry that never
    /// became one.
    private func commitImageFileLimit() {
        imageFileLimitText = String(ImageFileHanging.limitMB)
    }

    var body: some View {
        Form {
            Section {
                Text(L("Copies & pictures"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(L("Copy with formatting"), isOn: $copyFormatted)
                Text(copyFormatted
                     ? L("Single click copies and double click pastes with the formatting; a drag always comes out plain. Right-click holds Copy plain text, for the times formatting gets in the way.")
                     : L("Single click copies and double click pastes as plain text. Right-click holds Copy formatted, for the times you want it anyway."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: copyFormatted) { _, on in
                FormatCopy.isEnabled = on
            }

            // Pictures, one card: how a copied picture file shows, and the
            // folders whose new pictures hang by themselves. One container,
            // because both are answers to the same question — what happens
            // to a picture when it reaches the line.
            Section {
                Toggle(L("Picture files show as thumbnails"), isOn: $imageFilesAsPictures)
                if imageFilesAsPictures {
                    // Typed, not stepped: the limit is the user's own answer
                    // to "how big is worth copying", and a wheel of clicks is
                    // no way to answer it. Applied the moment it parses as a
                    // whole number in range; an entry that does not parse
                    // goes back to the last one that did, on submit.
                    HStack {
                        Text(L("Copy limit"))
                        Spacer()
                        LimitField(text: $imageFileLimitText, onSubmit: commitImageFileLimit)
                            .frame(width: 72)
                        Text("MB")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 4)
                    }
                    Text(L("When on, a copied picture file keeps a copy of itself in the app's folder, so the picture does not vanish when the original is deleted. A picture over the limit (1–1024 MB) shows only a file icon and hangs by reference: when the original is deleted the card greys out and can no longer be copied."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("A copied picture file hangs as a reference to the original, exactly like any other file."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: imageFilesAsPictures) { _, on in
                ImageFileHanging.isEnabled = on
            }
            .onChange(of: imageFileLimitText) { _, text in
                if let mb = Self.parsedLimit(text) {
                    ImageFileHanging.limitMB = mb
                }
            }

            // The folders the user asked to watch, in a container of their
            // own: these rows come and go with the user's list rather than
            // sitting under one switch, and a watch is a promise about the
            // world outside the app, not a question about the cards already
            // on it.
            Section {
                // The headline row carries the add button, the folders it
                // has follow, and the promise comes last: the button is what
                // the eye is here for, the words are for the moment after.
                HStack {
                    Text(L("Add folders to watch"))
                    Spacer()
                    Button(L("Add Folder…")) { addFolder() }
                        .buttonStyle(CDSPillButtonStyle())
                }
                ForEach(folders) { entry in
                    watchedFolderRow(entry)
                }
                Text(L("Watch a folder and every new picture in it hangs on the line by itself. Add the folder where macOS saves screenshots (⌘⇧3 / ⌘⇧4 / ⌘⇧5) — by default, the Desktop."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear(perform: refreshFolderRows)
        }
        .formStyle(.grouped)
        // CDS / Flyring arrangement: hand the Form's own grey back, let the
        // window's warm ground (CDS.ground) show through, and the grouped
        // cards — the system's own white cards — float on that paper. The
        // tab strip above wears the same ground, so strip and page read as
        // one continuous background.
        .scrollContentBackground(.hidden)
        // The menu bar carries this same switch, and this window is kept alive
        // rather than rebuilt, so reading the answer on the way in would leave
        // the tick here showing the one it had then — see `SettingsAnswers`.
        .onReceive(NotificationCenter.default.publisher(for: .settingsAnswerChanged)) { _ in
            copyFormatted = FormatCopy.isEnabled
        }

    }

    // MARK: Watched folders

    /// The rows under "Also watch folders", read back from the store. The
    /// stale marks are computed here rather than held by the store: whether
    /// a ticket still resolves is a question for the moment the page is
    /// shown, not a fact to keep.
    @State private var folders: [FolderWatchStore.Entry] = []
    @State private var staleFolders: Set<UUID> = []

    /// Reads the store back into the rows and marks the entries whose
    /// tickets no longer resolve, then lets the app bring its watchers in
    /// line with what the page now shows.
    private func refreshFolderRows() {
        folders = FolderWatchStore.entries
        staleFolders = Set(folders.filter { FolderWatchStore.resolve($0) == nil }.map(\.id))
    }

    /// Every change the page makes goes through here once: the rows read the
    /// store again, and the app's watchers follow the list.
    private func commitFolderChange() {
        refreshFolderRows()
        LineKeeper.folderWatchSync?()
    }

    /// One watched folder: its name on the left, and on the right the switch
    /// between watching and not — or, for a folder the system can no longer
    /// reach, the re-pick that renews the ticket. Removal is separate and
    /// asks nothing: taking a folder off the list leaves the cards that came
    /// from it alone, so there is nothing lost to confirm.
    private func watchedFolderRow(_ entry: FolderWatchStore.Entry) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if staleFolders.contains(entry.id) {
                    Button(L("Re-pick")) { repickFolder(entry) }
                        .buttonStyle(CDSPillButtonStyle())
                } else {
                    Button(entry.enabled ? L("Stop Watching") : L("Watch")) {
                        FolderWatchStore.setEnabled(entry.id, !entry.enabled)
                        commitFolderChange()
                    }
                    .buttonStyle(CDSPillButtonStyle())
                }
                Button {
                    FolderWatchStore.remove(entry.id)
                    commitFolderChange()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                if staleFolders.contains(entry.id) {
                    Text(L("This folder cannot be reached right now. Pick it again to keep watching it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The picker the add and the re-pick share. Folders only, one at a
    /// time: a watch is a promise about one place.
    private func pickFolder(startingAt start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = start
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func addFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // The Desktop is where the promise does the most good: screenshots
        // land there already, so watching it is one pick and nothing else.
        guard let url = pickFolder(startingAt: home.appendingPathComponent("Desktop")) else { return }
        guard FolderWatchStore.isWatchable(url) else {
            folderAlert(L("Cannot watch this folder"),
                        L("The app's own folder, and everything around or inside it, is already covered: pictures landing there hang without help."))
            return
        }
        guard FolderWatchStore.add(url) != nil else {
            folderAlert(L("Cannot watch this folder"),
                        L("This folder is being watched already."))
            return
        }
        commitFolderChange()
    }

    /// The re-pick of a folder whose ticket went stale — the folder was
    /// moved, renamed, or forgotten by the system. The new ticket takes the
    /// old entry's place: same row, same on/off state, same watcher.
    private func repickFolder(_ entry: FolderWatchStore.Entry) {
        guard let url = pickFolder(startingAt: FolderWatchStore.resolve(entry)) else { return }
        guard FolderWatchStore.replace(entry.id, with: url) else {
            folderAlert(L("Cannot watch this folder"),
                        L("This folder is being watched already."))
            return
        }
        commitFolderChange()
    }

    private func folderAlert(_ title: String, _ informative: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// The copy-limit box, wrapped so a fresh window cannot wake it.
///
/// A window made key hands its focus to the first text field it finds — the
/// caret blinking in a number box the user never touched, and the first
/// keystroke stolen from whatever they opened the settings to read. SwiftUI
/// has no say against that: the window's own first-responder choice is made
/// underneath it, and a focus state bound to false is overruled the moment
/// the window becomes key. So the refusal is the box's own — this text field
/// answers `false` to becoming first responder until it has been clicked,
/// which is the one way anyone ever means to type a number into it.
private struct LimitField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ClickAwakeTextField {
        let field = ClickAwakeTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: ClickAwakeTextField, context: Context) {
        // Only from the outside in: while the field is the one being edited
        // its own string is the truth, and writing the binding back would
        // move the caret.
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LimitField
        init(_ parent: LimitField) { self.parent = parent }

        @objc func submitted() { parent.onSubmit() }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// A text field that sleeps until it is clicked.
private final class ClickAwakeTextField: NSTextField {
    /// Whether the field has been clicked — the only thing that ever asks
    /// for it to be typed into. Until then it refuses first responder, so a
    /// window looking for somewhere to put its focus finds nothing here.
    private var awake = false

    override func becomeFirstResponder() -> Bool {
        awake ? super.becomeFirstResponder() : false
    }

    override func mouseDown(with event: NSEvent) {
        awake = true
        super.mouseDown(with: event)
    }
}

/// A field whose life is one paste, and which therefore sleeps until it is
/// clicked.
///
/// The same refusal `LimitField` makes, for the same reason. The difference is
/// the commit: a limit is applied as it parses, character by character, while
/// these three are written back when the field is done being edited — one
/// keychain write per pasted key rather than one per character.
private struct SleepyField: NSViewRepresentable {
    @Binding var text: String
    var secure = false
    var prompt: String = ""
    /// Return, or a click somewhere else. Whatever the field really writes to.
    var commit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        // NSSecureTextField is an NSTextField, so one signature serves both;
        // the two subclasses below differ only in which one they start from.
        let field: NSTextField = secure ? ClickAwakeSecureField() : ClickAwakeTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        // A key and an address are read character by character — "is that an
        // l or a 1" — so they are set in a monospaced face, small enough that
        // a whole URL fits. No ellipsis: what is longer than the box is
        // clipped, which is the field's own default and does not lie about
        // what is in it.
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        if !prompt.isEmpty { field.placeholderString = prompt }
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only from the outside in: while the field is being edited its own
        // string is the truth, and writing the binding back would move the
        // caret to the end of the line under the person's fingers.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SleepyField
        init(_ parent: SleepyField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return, Tab, or a click anywhere else all end editing, which is the
        /// one moment worth writing to the keychain.
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.commit()
        }
    }
}

/// `ClickAwakeTextField`'s refusal, for the field that shows dots.
private final class ClickAwakeSecureField: NSSecureTextField {
    private var awake = false

    override func becomeFirstResponder() -> Bool {
        awake ? super.becomeFirstResponder() : false
    }

    override func mouseDown(with event: NSEvent) {
        awake = true
        super.mouseDown(with: event)
    }
}

// MARK: - Invocation

/// How the line is called down, and the two keys that call it. Everything on
/// this page answers one question — "how does the rope come to me" — which is
/// why it is a page of its own rather than rows folded into the general one.
struct InvocationPage: View {
    @State private var style = DropDeck.style
    @State private var left = DropDeck.left
    @State private var right = DropDeck.right
    @State private var defaultDeck = DropDeck.defaultDeck
    @State private var flip = DropDeck.flip
    @State private var rest = DropDeck.rest
    /// Whether the two marks are drawn on the rope, mirrored from `RopeMark`
    /// so a switch thrown here takes effect on a rope that is already down.
    @State private var showNoteMark = RopeMark.isShown(.note)
    @State private var showPropMark = RopeMark.isShown(.prop)

    /// The two decks, called by the names the rest of the settings use.
    private var deckOptions: some View {
        Group {
            Text(L("Clipboard")).tag(Line.Deck.clipboard)
            Text(L("Notes")).tag(Line.Deck.notes)
        }
    }

    var body: some View {
        Form {
            Section {
                // The section's name as a headline row inside the card (the
                // Flyring house style), so the picker beside it can stay
                // "Style" without saying the same thing twice.
                Text(L("How the line comes down"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker(L("Style"), selection: $style) {
                    Text(L("Left and right of the notch")).tag(DropDeck.Style.halves)
                    Text(L("A modifier key")).tag(DropDeck.Style.modifier)
                }
                if style == .halves {
                    Picker(L("Left half"), selection: $left) {
                        deckOptions
                    }
                    Picker(L("Right half"), selection: $right) {
                        deckOptions
                    }
                } else {
                    Picker(L("Default deck"), selection: $defaultDeck) {
                        deckOptions
                    }
                    Picker(L("Flip key"), selection: $flip) {
                        ForEach(DropDeck.Flip.allCases, id: \.self) { key in
                            Text(key.label).tag(key)
                        }
                    }
                }
                Picker(L("Rest delay"), selection: $rest) {
                    ForEach(DropDeck.Rest.allCases, id: \.self) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                Text(style == .halves
                     ? L("Rest on the left of the notch for one deck, on the right for the other. On a display without a notch, resting on the menu bar brings the left half's deck.")
                     : L("Resting brings the default deck; holding the flip key brings the other one."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // The door each key opens is written beside it: a bare
                // combination would send every reader to the menu to decode
                // which rope it pulls down.
                Text(L("Shortcuts"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LabeledContent(L("Open the clipboard")) {
                    HotkeyRecorder(door: .clipboard)
                }
                LabeledContent(L("Open the notes")) {
                    HotkeyRecorder(door: .notes)
                }
                // The capture's key is not here. It opens no line, so it is the
                // one shortcut that is not a way of reaching the rope — and a
                // row about it would be the only one on this page whose key led
                // somewhere else. It is recorded on the Capture page, beside
                // everything else about capturing.
                Text(L("Click one, then press the new combination. Esc cancels."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The buttons that act on a line already down, and no keys for
            // them (2026-10-22). Their shortcuts were bare letters answered
            // for as long as the line was down — which is also true while
            // somebody types into another app, and the n being typed became a
            // new note. Until a key can tell a hand on the rope from a hand on
            // a keyboard, the line holds no letters at all (see
            // `Door.panelDoors`), so there is nothing to record here.
            Section {
                Text(L("While the line is down"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // New note: the button on the rope is the whole of the door.
                Toggle(L("Show the new note button"), isOn: $showNoteMark)
                // Restored together with the key: uncomment this row. Its
                // label is still in both .strings files.
                // LabeledContent(L("New note shortcut")) {
                //     HotkeyRecorder(door: .note, requiresModifier: false)
                // }

                // Keep-down: the button on the rope, which locks the rope the
                // line is showing.
                Toggle(L("Show the lock button"), isOn: $showPropMark)
                // Restored together with the key, as above.
                // LabeledContent(L("Lock the rope shortcut")) {
                //     HotkeyRecorder(door: .prop, requiresModifier: false)
                // }

                // One paragraph, small and grey: where the two buttons are,
                // and the one key that still answers here. The sentence about
                // the letter keys is kept with them, in `Door.panelDoors`.
                Text(L("The two buttons sit on the rope, in the dip above the cards. A propped line is put away with Esc from anywhere."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: showNoteMark) { _, on in
                RopeMark.setShown(.note, on)
                LineKeeper.line?.showsNoteMark = on
            }
            .onChange(of: showPropMark) { _, on in
                RopeMark.setShown(.prop, on)
                LineKeeper.line?.showsPropMark = on
            }
        }
        .formStyle(.grouped)
        // CDS / Flyring arrangement: hand the Form's own grey back, let the
        // window's warm ground (CDS.ground) show through, and the grouped
        // cards — the system's own white cards — float on that paper. The
        // tab strip above wears the same ground, so strip and page read as
        // one continuous background.
        .scrollContentBackground(.hidden)
        .onChange(of: style) { _, on in
            DropDeck.style = on
        }
        .onChange(of: left) { _, deck in
            DropDeck.setDeck(deck, forKey: "dropDeckLeft")
        }
        .onChange(of: right) { _, deck in
            DropDeck.setDeck(deck, forKey: "dropDeckRight")
        }
        .onChange(of: defaultDeck) { _, deck in
            DropDeck.setDeck(deck, forKey: "dropDeckDefault")
        }
        .onChange(of: flip) { _, key in
            DropDeck.flip = key
        }
        .onChange(of: rest) { _, speed in
            DropDeck.rest = speed
        }
    }
}

// MARK: - Capture

/// Everything about taking a picture of the screen: the key that starts it,
/// what happens to the picture, and the folder macOS's own captures land in.
///
/// A page of its own rather than rows on the Invocation page, for two reasons.
/// The capture is the one door that opens no line — its key leads somewhere
/// else, and a shortcut row about it would be the only one on that page that
/// did. And the questions are not "how does the rope come to me" but "what
/// becomes of a capture", which is a different subject with its own answers.
///
/// Mostly controls, and no paragraphs of advocacy (2026-11-02, user). The three
/// switches it started with explain nothing because there is nothing to
/// explain: each one's consequence is its own name. What came here on
/// 2026-11-03 brought its own sentences, and those are of the other kind — a
/// caption under the language row because the answer it used to carry moved
/// into the capture, and a caption under the editor switch because ⌘-keys are
/// deliberately not marked. Both are one line and both say a fact. What needs
/// saying about the permission is said on the Permissions page, where it can be
/// acted on.
///
/// Six cards on a 620-point page, and the order is the order of the questions
/// people arrive with: how do I summon it, what happens after, where do the
/// system's own screenshots go, then the two cards about what a capture can do
/// with what is on the screen. The key and address hide behind a triangle — the
/// one thing here answered once a year.
struct CapturePage: View {
    /// Whether something new shows itself for a moment. The same switch the
    /// menu carries as "Peek at new cards": a capture is one of the things
    /// that arrives, so it belongs beside the rest of the capture's answers.
    @State private var peeks = AppDelegate.peeksAtNew
    @State private var inbox = Inbox.screenshotInboxEnabled

    /// The shortlist the capture bar's menu offers. What a press of `译`
    /// actually uses is deliberately not here — it is chosen in that menu,
    /// which is where the question comes up.
    @State private var targetCodes = TranslationTargets.chosen
    /// The three fields that choose the other end of the wire. Read on the way
    /// in and written back on commit rather than on every keystroke: a
    /// keychain write per character would be a keychain write per character.
    @State private var apiKey = TranslationAPI.key
    @State private var apiModel = TranslationAPI.model
    @State private var apiEndpoint = TranslationAPI.endpoint
    @State private var testing = false
    @State private var testResult: String?
    /// The capture editor's corner letters. This is the page the editor's other
    /// answers are on, so the switch that changes them is here too.
    @State private var shortcutHints = ShortcutHints.isEnabled
    /// Whether the key and address are showing. Remembered for the life of the
    /// window only: a page that reopened with the triangle down would be a page
    /// that scrolls again for anybody who left it open once.
    @State private var apiExpanded = false

    var body: some View {
        Form {
            Section {
                Text(L("Shortcuts"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LabeledContent(L("Capture the screen")) {
                    HotkeyRecorder(door: .capture)
                }
            }

            Section {
                Text(L("After a capture"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(L("Show the line when something new arrives"), isOn: $peeks)
            }

            Section {
                Text(L("The screenshot folder"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
#if !APPSTORE_LITE
                Toggle(L("Hang new screenshots"), isOn: $inbox)
#endif
            }
            // The capture editor's corner letters, in the page whose cards are
            // about what happens to a captured thing.
            Section {
                Text(L("Capture editor"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(L("Show capture editor shortcuts"), isOn: $shortcutHints)
                Text(L("Each tool shows its letter key in the corner. Copy, Overwrite and the zoom keys use the usual ⌘ combinations and are left plain."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: shortcutHints) { _, on in
                // The setter posts the notification the open editor windows are
                // listening for, so the corners change while the switch is still
                // under the pointer.
                ShortcutHints.isEnabled = on
            }
            // What the 译 button in the capture has to choose from. The
            // shortlist only, and only one row of it: which language a press
            // actually answers in is chosen in the menu under that button, which
            // is where the question comes up. A second control here answered a
            // question nobody asked twice, and the person using it said so.
            Section {
                Text(L("Translation"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A menu of ticked rows rather than ten switches on the page —
                // a settings list that pushes everything under it off the bottom
                // is the one failure this window has had before.
                LabeledContent(L("Languages")) {
                    Menu {
                        ForEach(TranslationCatalogue.all) { option in
                            Toggle(option.name, isOn: Binding(
                                get: { targetCodes.contains(option.code) },
                                set: { on in toggleLanguage(option.code, on) }))
                        }
                    } label: {
                        Text(targetCodes.compactMap { TranslationCatalogue.named($0)?.name }
                            .joined(separator: " · "))
                    }
                    .frame(width: 300, alignment: .leading)
                }
                // One caption, because a question left the page: with the picker
                // gone, "which one is it using right now" has no answer here and
                // the row above would look like the whole story.
                Text(L("The translate button's menu offers exactly these. Which one it uses is chosen there."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Collapsed by default. Three cards came to this page and the page
            // is 620 points tall: left open, this one pushed the editor's switch
            // past the bottom edge, where it was still there and still
            // unreachable. What is behind the triangle is a key and an address,
            // set once and then forgotten — so it is the one thing here that can
            // afford to be a click away.
            Section {
                // The triangle is drawn here rather than handed to SwiftUI's
                // `DisclosureGroup`, because in a grouped `Form` that control
                // lays its label out as a row of the label's own height: 40
                // points from the header to the first field, against 74 from
                // 「翻译」 to 「语言清单」 in the card above (measured off a
                // screenshot, 2026-11-03 — 「展开后的菜单明显高度与其他不同」).
                // The affordance has to stay, the metrics have to be the page's.
                // So: one ordinary first row, a headline like every other card
                // opens with, and the chevron after the words — after, not
                // before, so all four card titles start on the same vertical.
                Button {
                    withAnimation(CDS.microAnimation) { apiExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(L("Translation API"))
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(apiExpanded ? 0 : -90))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if apiExpanded {
                    LabeledContent(L("Address")) {
                        SleepyField(text: $apiEndpoint, prompt: TranslationAPI.defaultEndpoint) {
                            TranslationAPI.endpoint = apiEndpoint
                        }
                        .frame(width: 300)
                    }
                    LabeledContent(L("Model")) {
                        SleepyField(text: $apiModel, prompt: TranslationAPI.defaultModel) {
                            TranslationAPI.model = apiModel
                        }
                        .frame(width: 300)
                    }
                    LabeledContent(L("API key")) {
                        HStack(spacing: 8) {
                            SleepyField(text: $apiKey, secure: true, prompt: "sk-…") {
                                TranslationAPI.key = apiKey
                            }
                            .frame(width: 240)
                            Button(L("Clear")) { clearKey() }
                                .buttonStyle(CDSPillButtonStyle())
                                .disabled(apiKey.isEmpty)
                        }
                    }
                    HStack(spacing: 10) {
                        Button(testing ? L("Testing…") : L("Test")) { runTest() }
                            .buttonStyle(CDSPillButtonStyle())
                            .disabled(testing || apiKey.isEmpty)
                        if let testResult {
                            Text(testResult)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                    Text(L("If this API key is filled in, translation uses that key's model by default."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            // The menu can move either of these while this window is open.
            // Read again on the way in, so the page never shows an answer that
            // was true when the window was built.
            peeks = AppDelegate.peeksAtNew
            inbox = Inbox.screenshotInboxEnabled
            // The key is in the keychain and the other two are in the
            // preferences, none of them in this view's state, so the page reads
            // them back each time it comes up. A settings window is kept alive
            // rather than rebuilt; without this, a key pasted in once would show
            // blank on the next visit and look as though it had not been saved.
            apiKey = TranslationAPI.key
            apiModel = TranslationAPI.model
            apiEndpoint = TranslationAPI.endpoint
            // The shortlist can be changed from the capture's own menu, and this
            // page is kept alive rather than rebuilt.
            targetCodes = TranslationTargets.chosen
            shortcutHints = ShortcutHints.isEnabled
        }
        // And while it is open, follow: the window outlives every visit (it is
        // kept rather than released when closed), so reading on the way in is
        // only half the job — the menu bar's copy of these same two switches
        // moves them behind this page's back. Every setter announces, and stays
        // quiet when nothing changed, so the echo these cause dies here instead
        // of ping-ponging.
        .onReceive(NotificationCenter.default.publisher(for: .settingsAnswerChanged)) { _ in
            peeks = AppDelegate.peeksAtNew
            inbox = Inbox.screenshotInboxEnabled
        }
        .onChange(of: peeks) { _, on in
            AppDelegate.peeksAtNew = on
        }
        .onChange(of: inbox) { _, on in
            AppDelegate.setScreenshotInboxFromSettings(on)
        }
    }

    /// Ticks or unticks one language in the shortlist.
    ///
    /// The last one cannot be unticked: the menu in the capture would then be
    /// empty, and a menu with nothing in it is a button that has stopped
    /// working with no way to see why. Unticking the one in force moves the
    /// answer to whatever is left, which `TranslationTargets.chosen` does on
    /// the way in.
    private func toggleLanguage(_ code: String, _ on: Bool) {
        var codes = targetCodes
        if on {
            if !codes.contains(code) { codes.append(code) }
        } else {
            guard codes.count > 1 else { return }
            codes.removeAll { $0 == code }
        }
        TranslationTargets.chosen = codes
        // Read back rather than trusting the argument: the setter de-duplicates
        // and puts them in the catalogue's order, and it may have moved the
        // language in force because the one it was pointing at has just gone —
        // which this page no longer shows, but the bar's next press will.
        targetCodes = TranslationTargets.chosen
    }

    /// Empties the key, which is also the way back to the system's engine:
    /// an emptied field deletes the keychain item rather than storing a blank
    /// one, and "no key" is what `TranslationAPI.isConfigured` reads.
    private func clearKey() {
        apiKey = ""
        TranslationAPI.key = ""
        testResult = nil
    }

    /// One real round trip, from the button that promises one.
    ///
    /// The three faults people actually hit — a key that was revoked, a model
    /// name that has been retired, an address with no network behind it — come
    /// back as three different sentences, because they need three different
    /// fixes. A single "failed" would leave the next step to guesswork.
    private func runTest() {
        guard !testing else { return }
        // Committed first: the button is often pressed in the same second as
        // the last keystroke, and a test of the previous key is worse than no
        // test at all — it passes, and the translation then fails.
        TranslationAPI.key = apiKey
        TranslationAPI.model = apiModel
        TranslationAPI.endpoint = apiEndpoint
        testing = true
        testResult = nil
        Task { @MainActor in
            let outcome = await TranslationAPI.test()
            testing = false
            testResult = (outcome.ok ? L("Works") : L("Did not work")) + " · " + outcome.detail
        }
    }

}

// MARK: - Shortcuts

/// One door's shortcut, caught rather than typed.
///
/// A button wearing the combination it stands for; pressing it puts the view
/// in the listening state, and the next key combination that arrives —
/// through a local monitor, while this window is key and nothing else is
/// typing — becomes the door's new key. Esc is the way out. A bare key is
/// refused to a door answered everywhere (a global key that ate a plain
/// letter would be a key the whole machine pays for) but is the whole point
/// of the two the panel answers inside its own height, and a combination the
/// other door already holds is refused with a word rather than silently
/// stacked.
struct HotkeyRecorder: View {
    let door: Door
    /// Whether a combination with no modifier is an answer.
    ///
    /// True for the two summons, because they are registered globally and a
    /// bare letter given to Carbon is a letter taken out of every app on the
    /// machine. False for the two doors the panel answers inside its own
    /// height, where a bare key costs nothing — which is why those two default
    /// to the plain letter the user asked for.
    var requiresModifier: Bool = true

    /// What the pill wears while it is idle: the door's key, or a dash when
    /// the door has none.
    ///
    /// Held as this view's own state rather than read from the door in the
    /// body, because recording and clearing write the defaults behind
    /// SwiftUI's back. SwiftUI redraws for the state a body actually reads,
    /// and a body that reads none of its own has nothing that can tell it to
    /// draw again — which is how a cleared key stayed on the pill until the
    /// window was reopened.
    @State private var shown: String
    @State private var recording = false
    @State private var conflict = false
    @State private var keyMonitor: Any?
    @State private var clickMonitor: Any?

    init(door: Door, requiresModifier: Bool = true) {
        self.door = door
        self.requiresModifier = requiresModifier
        _shown = State(initialValue: door.displayOrNone)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : listen()
            } label: {
                // Two things the label can say: the combination it stands
                // for, and the fact that it is listening. A refusal — the
                // same key another door already holds — is the one answer
                // this recorder cannot keep. A door that has been emptied
                // shows a dash.
                Group {
                    if conflict {
                        Text(L("Already used by another shortcut."))
                    } else if recording {
                        Text(L("Type the new shortcut…"))
                    } else {
                        Text(shown)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(recording ? Color.white : (conflict ? Color.red : Color.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                // Wide enough that the refusal ("already used…") does not
                // change the pill's width and shove the row around while it is
                // read.
                .frame(minWidth: 130)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(recording ? CDS.clay : Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A door can be turned off rather than given a different key —
            // the empty state is a real answer, not a leftover. The
            // affordance shows while a key is set and the recorder is not
            // listening; the dash on the pill is what it leaves behind.
            if door.isSet, !recording {
                Button(L("Clear"), action: clear)
                    .buttonStyle(CDSPillButtonStyle())
            }
        }
        // Read back on every appearance, so a window reopened after the key
        // was changed elsewhere shows what is actually stored.
        .onAppear { shown = door.displayOrNone }
    }

    /// Empties the door, leaving it with no key — the shortcut is off until
    /// a new one is recorded. The registration side refuses the empty marker
    /// (see `Door.clear`), so this only ever unregisters, never crashes.
    private func clear() {
        door.clear()
        AppDelegate.reregisterHotkeys()
        shown = door.displayOrNone
    }

    /// Listening: the window's own key events come here first, and the ones
    /// that answer are consumed. Outside clicks end the listening without
    /// eating the click — the hand that went elsewhere did not mean to type.
    private func listen() {
        recording = true
        conflict = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            take(event) ? nil : event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            stop()
            return event
        }
    }

    /// One key event, judged. Returns whether it was an answer (and so
    /// consumed) or something to ignore — which keeps listening, because a
    /// key with no modifier in it is a slip, not a decision.
    private func take(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) { stop(); return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // A door that is answered everywhere insists on a modifier, because a
        // bare letter registered globally is a bare letter removed from every
        // other app. A door the panel answers inside its own height does not:
        // the hand is on the rope, not in a document, so a plain letter is
        // exactly as safe as a combination and much easier to press. So a
        // keypress is kept when it carries a modifier, or when the door is
        // one that does not ask for one — and only a bare key aimed at a door
        // that does ask is the slip that is ignored.
        guard !requiresModifier || !flags.isEmpty else { return false }

        let code = Int(event.keyCode)
        let carbon = Door.carbonModifiers(from: flags)
        // Any other door that already holds this exact key, of either kind.
        // The two kinds never collide with each other in practice — a summon
        // always carries a modifier and a panel door by default does not — but
        // the check is by value rather than by pair, so a user who records a
        // modifier on a panel door is still refused a duplicate rather than
        // being allowed two doors on one key.
        if let clash = Door.allCases.first(where: {
            $0 != door && $0.keyCode == code && $0.carbonModifiers == carbon
        }) {
            _ = clash
            stop()
            conflict = true
            return true
        }
        let character = event.charactersIgnoringModifiers?
            .uppercased().first.map(String.init) ?? door.displayCharacter
        door.set(code: code, modifiers: carbon, character: character)
        AppDelegate.reregisterHotkeys()
        shown = door.displayOrNone
        stop()
        return true
    }

    private func stop() {
        recording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }
}

// MARK: - Keeping

struct KeepingPage: View {
    @State private var stats = StorageStats.measure()
    @State private var retention = Attic.retentionDays
    /// Whether a sweep just ran. The button says so for a moment, because a
    /// destructive action that answers with silence is one the user runs
    /// twice to make sure.
    @State private var justCleaned = false

    var body: some View {
        Form {
            Section {
                Picker(L("Retention"), selection: $retention) {
                    ForEach([7, 14, 30, 90], id: \.self) { days in
                        Text("\(days) \(L("days"))").tag(days)
                    }
                }
                LabeledContent(L("Cards")) { Text("\(stats.cards)") }
                LabeledContent(L("Pictures")) { Text("\(stats.pictures)") }
                LabeledContent(L("On disk")) { Text(stats.size) }
                Text(L("Cards older than the window chosen here, and the pictures they came with, are cleared when the app starts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The three cleanups are one group: the name on the left says
            // what goes, the button on the right is the confirmation. Every
            // one of them asks once more before acting — a button that
            // empties a whole panel is one a stray click must not fire.
            Section {
                Text(L("Clean up"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LabeledContent(L("Clipboard pictures")) {
                    HStack(spacing: 8) {
                        Button(L("Open folder")) {
                            Inbox.prepare()
                            NSWorkspace.shared.open(Inbox.folder)
                        }
                        .buttonStyle(CDSPillButtonStyle())
                        Button(justCleaned ? L("Cleaned") : L("Clean up")) {
                            guard confirm(L("Clean up clipboard pictures?"),
                                          L("Pictures are put in the Trash rather than deleted, so anything cleared can be recovered.")) else { return }
                            LineKeeper.sweepNow()
                            stats = StorageStats.measure()
                            justCleaned = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                justCleaned = false
                            }
                        }
                        .disabled(justCleaned)
                        .buttonStyle(CDSPillButtonStyle())
                    }
                }

                LabeledContent(L("Clipboard cards")) {
                    Button(L("Clean up")) {
                        guard confirm(L("Clear the clipboard?"),
                                      L("Everything on the clipboard comes down. Its pictures are put in the Trash rather than deleted.")) else { return }
                        LineKeeper.line?.clear(deck: .clipboard)
                        stats = StorageStats.measure()
                    }
                    .buttonStyle(CDSPillButtonStyle())
                }
                .disabled(!(LineKeeper.line?.hasCards(.clipboard) ?? false))

                LabeledContent(L("Notes")) {
                    Button(L("Clean up")) {
                        guard confirm(L("Clear every note?"),
                                      L("The notes are kept nowhere else, so this cannot be undone.")) else { return }
                        LineKeeper.line?.clear(deck: .notes)
                        stats = StorageStats.measure()
                    }
                    .buttonStyle(CDSPillButtonStyle())
                }
                .disabled(!(LineKeeper.line?.hasCards(.notes) ?? false))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Pictures are put in the Trash rather than deleted, so anything cleared can be recovered."))
                    Text(L("The notes are kept nowhere else, so this cannot be undone."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // CDS / Flyring arrangement: hand the Form's own grey back, let the
        // window's warm ground (CDS.ground) show through, and the grouped
        // cards — the system's own white cards — float on that paper. The
        // tab strip above wears the same ground, so strip and page read as
        // one continuous background.
        .scrollContentBackground(.hidden)
        .onChange(of: retention) { _, days in
            Attic.retentionDays = days
        }
    }

    /// The second look every cleanup gives. An alert that says what is being
    /// lost is the only honest form of a question about going on — and a
    /// button that empties a whole panel is one a stray click must not fire.
    private func confirm(_ title: String, _ informative: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.addButton(withTitle: L("Clean up"))
        alert.addButton(withTitle: L("Keep them"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Permissions

struct PermissionsPage: View {
    var body: some View {
        // Checked again every second while this page is on the screen, rather
        // than held in a @State captured once: the granting happens in System
        // Settings, another app, so nothing inside this window will announce
        // it. A timeline that ticks only while the view is in the hierarchy
        // costs nothing on the other pages — and "check again" stops being a
        // button the user has to know to press.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let trusted = AccessibilityPermission.isTrusted

            Form {
                Section {
                    Text(L("Permissions"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    permissionRow(granted: trusted)
                    ScreenRecordingPermissionRow()
                    NotificationPermissionRow()
                    MicrophonePermissionRow()
                }

                // The bug-judging corner, in the Flyring house shape: the
                // name, the small words under it, and a row of small buttons.
                // A log only helps on the day something misbehaves, so the
                // doors to it sit here quietly rather than anywhere they
                // would be in the way.
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Diagnostics"))
                            .font(.headline)
                        Text(L("Logs stay on this Mac and rotate on their own. To report a bug, export the diagnostics — the log and the newest crash report in one file."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button(L("Open the log folder")) {
                                NSWorkspace.shared.open(ClothespegLog.directoryURL)
                            }
                            .buttonStyle(CDSPillButtonStyle())
                            Button(L("Copy Logs")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ClothespegLog.allText, forType: .string)
                            }
                            .buttonStyle(CDSPillButtonStyle())
                            Button(L("Export diagnostics…")) {
                                exportDiagnostics()
                            }
                            .buttonStyle(CDSPillButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// The permission as Flyring draws it: an icon that answers with colour,
    /// the name beside a status badge, the small print under them, and one
    /// small door to the place the permission is given.
    private func permissionRow(granted: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Accessibility"))
                        .font(.callout)
                        .fontWeight(.medium)
                    Label(granted ? L("Granted") : L("Not granted"),
                          systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(granted ? .green : .orange)
                }
                Text(L("Once it is allowed, double-clicking a card copies the content and pastes it into the field your pointer is in. Without it, double-clicking only copies, and you have to press ⌘V yourself. macOS does not let an app control another app freely, which is why this needs its own permission. Nothing is read and nothing is recorded."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                // Worth saying exactly once, and only when it can still
                // happen: a granted permission does not need a warning.
                if !granted {
                    Text(L("After granting it, macOS may ask you to reopen Clothespeg."))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Button(L("Open System Settings")) {
                    AccessibilityPermission.openSettings()
                }
                .buttonStyle(CDSPillButtonStyle())
            }
            Spacer(minLength: 0)
        }
    }

    /// 导出诊断包（运行日志 + 最近崩溃报告）为一个文本文件，导出后在 Finder 中定位。
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Clothespeg诊断包-\(stamp.string(from: Date())).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ClothespegLog.exportPackage(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = L("Could not export the diagnostics")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

/// The screen recording row: the one permission that guards a whole feature
/// rather than a convenience.
///
/// Accessibility turns a double-click's paste into a plain copy, Notifications
/// turns a closed-app reminder into none at all — both are a layer taken off
/// something that still works. This one is different in kind: without it the
/// capture shortcut does nothing whatsoever, so "not granted" is not a quieter
/// version of the feature, it is the absence of it.
///
/// Two silences, two buttons. macOS shows its own prompt exactly once; after a
/// refusal it will not show it again from inside the app, and asking again
/// simply returns "no" without asking anything. `hasAsked` is what tells the
/// two apart, so the row can offer the question where a question is still
/// possible and the settings pane where it is not.
private struct ScreenRecordingPermissionRow: View {
    @State private var granted = ScreenRecordingPermission.isGranted
    @State private var asked = ScreenRecordingPermission.hasAsked
    @State private var busy = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "viewfinder")
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Screen recording"))
                        .font(.callout)
                        .fontWeight(.medium)
                    Label(granted ? L("Granted") : L("Not granted"),
                          systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(granted ? .green : .orange)
                }
                Text(L("Clothespeg uses it for one thing: taking the picture when you press the capture shortcut. Without it that shortcut does nothing at all. Nothing is recorded, and nothing leaves this Mac."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                // Worth saying exactly once, and only after asking: a grant
                // that has not been taken up looks identical to a refusal from
                // inside the running app, and the fix is the one thing the
                // user would not guess.
                if !granted && asked {
                    Text(L("After granting it, macOS asks you to open Clothespeg again — a permission only reaches a process that started after it was given."))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if !granted {
                    if asked {
                        Button(L("Open System Settings")) {
                            ScreenRecordingPermission.openSettings()
                        }
                        .buttonStyle(CDSPillButtonStyle())
                    } else {
                        Button(L("Allow Screen Recording")) { ask() }
                            .buttonStyle(CDSPillButtonStyle())
                            .disabled(busy)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        // The granting happens in System Settings, another app, so nothing in
        // this window announces it. Keep asking while the row is on screen,
        // the same way the page re-checks Accessibility every second.
        .task {
            while !Task.isCancelled {
                granted = ScreenRecordingPermission.isGranted
                asked = ScreenRecordingPermission.hasAsked
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// The question, put once.
    ///
    /// `CGRequestScreenCaptureAccess` blocks while the system's own prompt is
    /// up, and answers false in the case that matters most — granted, but not
    /// yet taken up by this process. So the answer is read back rather than
    /// assumed, and the row then says what to do about a false that is not a
    /// refusal.
    private func ask() {
        busy = true
        granted = ScreenRecordingPermission.request()
        asked = true
        busy = false
    }
}

/// The microphone row: the one permission the recording feature cannot work
/// without, and the one place a refusal can be undone.
///
/// macOS shows its prompt once. If it was answered no — or never appeared
/// because the app was in the background when it asked — the recording
/// panel alone cannot recover. So this row says which state the line is in
/// and offers the one action that still works, checked every second because
/// the granting happens in another app.
private struct MicrophonePermissionRow: View {
    @State private var state: MicrophonePermission.State = MicrophonePermission.state
    @State private var busy = false

    private var granted: Bool { state == .granted }

    private var badge: String {
        switch state {
        case .granted: return L("Granted")
        case .denied: return L("Not granted")
        case .undetermined: return L("Not asked yet")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "mic")
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Microphone"))
                        .font(.callout)
                        .fontWeight(.medium)
                    Label(badge,
                          systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(granted ? .green : .orange)
                }
                Text(L("Clothespeg uses the microphone for one thing: recording a voice memo on a note. The audio stays in a file beside your notes on this Mac and is never uploaded."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if state == .denied {
                    Text(L("After granting it, macOS asks you to open Clothespeg again — a permission only reaches a process that started after it was given."))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if !granted {
                    // Only macOS gets a say in which button is here. `hasAsked`
                    // is a note we wrote ourselves, and a first request that
                    // failed for a reason in the signature left it set: the
                    // row then hid "Allow Microphone" forever, even after TCC
                    // had gone back to undetermined and was willing to ask.
                    if state == .undetermined {
                        Button(L("Allow Microphone")) { ask() }
                            .buttonStyle(CDSPillButtonStyle())
                            .disabled(busy)
                    } else {
                        Button(L("Open System Settings")) {
                            MicrophonePermission.openSettings()
                        }
                        .buttonStyle(CDSPillButtonStyle())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .task {
            while !Task.isCancelled {
                state = MicrophonePermission.state
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func ask() {
        busy = true
        Task { @MainActor in
            _ = await MicrophonePermission.request()
            state = MicrophonePermission.state
            busy = false
        }
    }
}

/// The notification row: the one permission that is an extra layer rather
/// than the reminder itself.
///
/// The bell and the rope coming down are the app's own and need nothing from
/// the system. What this asks for is the banner and the system chime when
/// Clothespeg is not the window in front — so "not granted" is said plainly
/// rather than as a fault, and the reminder is still promised.
private struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var busy = false

    /// Provisional and ephemeral are ways of being allowed too; only a
    /// refusal or an unanswered question reads as "not granted" here.
    private var granted: Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Notifications"))
                        .font(.callout)
                        .fontWeight(.medium)
                    Label(granted ? L("Granted") : L("Not granted"),
                          systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(granted ? .green : .orange)
                }
                Text(L("Once it is allowed, the system shows a reminder notification even when the app is closed. Without it, a closed app has no reminder."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if status == .denied {
                    Text(L("Denied. macOS will not ask again from inside the app; open it in System Settings."))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if status == .notDetermined {
                    Button(L("Allow Notifications")) { ask() }
                        .buttonStyle(CDSPillButtonStyle())
                        .disabled(busy)
                } else {
                    Button(L("Open System Settings")) {
                        NotificationPermission.openSettings()
                    }
                    .buttonStyle(CDSPillButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
        // Granting happens in System Settings, another app, so nothing in
        // this window announces it. Keep asking while the row is on screen,
        // the same way the page re-checks Accessibility every second.
        .task {
            while !Task.isCancelled {
                status = await NotificationPermission.status()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func ask() {
        busy = true
        Task {
            _ = await NotificationPermission.request()
            status = await NotificationPermission.status()
            busy = false
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @State private var showLicence = false

    var body: some View {
        // Not a form. Flyring's about page reads as a small poster — the
        // icon, the name, the words, all centred and open — and grouped
        // cards around them made this one read as an insurance form. One
        // column, centred, nothing between the reader and the page.
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 104, height: 104)
                    .padding(.top, 34)

                Text("Clothespeg")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 14)

                Text(AppInfo.version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .padding(.top, 3)

                Text(L("Clothespeg takes its cue from Tendedero, Spanish for a clothesline. One line strings together a clipboard and a notebook: screenshots, text and files hang there, yours when you need them; notes hang there too, for a thought or a to-do, a glance away."))
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 18)

                Button(L("Licence")) { showLicence = true }
                    .buttonStyle(CDSPillButtonStyle())
                    .padding(.top, 22)
                    .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showLicence) { LicenceSheet() }
    }
}

/// The licence, with the attribution riding in the same scroll rather than
/// on the page. The licence notice is the condition of the reuse, so the notice
/// and the name it names belong together — a build that shows one without
/// the other has separated a debt from its receipt.
private struct LicenceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Clothespeg"))
                    .font(.system(size: 12, weight: .medium))
                Text(L("Licensed under the PolyForm Noncommercial License 1.0.0. Based on Tendedero by Alejandro Buján, used under the MIT License."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(LicenceText.full)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }
                    .buttonStyle(CDSPillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
        // Ground outside the padding: the sheet's own background must not
        // show as a ring around the warm ground, and the padding is what
        // keeps the text off the ground's edge.
        .settingsPageBackground()
    }
}

// MARK: - Shared pieces

enum AppInfo {
    /// The version, from the bundle rather than from a constant. A number
    /// written in two places is a number that is right in one of them.
    static var version: String {
        (Foundation.Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}

/// The ground the settings pages sit on.
///
/// The CDS warm ground (`CDS.ground`) rather than white-over-grey: in light
/// mode the window's own grey sat too close to the grey of the grouped cards
/// and one blurred into the other — the warm `#f5f5f3` gives the cards their
/// edges back the same way the white did, and matches the paper tone the
/// cards on the line wear. Dark mode is a warm charcoal rather than the
/// system's neutral grey, for the same reason.
private struct SettingsPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        // The licence sheet is not a Form, so it simply paints the CDS warm
        // ground behind its content. (The settings pages no longer use this:
        // they hand their Form's grey back with `.scrollContentBackground(
        // .hidden)` so the window's own ground shows through — the Flyring
        // arrangement, where the white cards float on the warm paper.)
        content
            .background(CDS.ground)
    }
}

private extension View {
    func settingsPageBackground() -> some View {
        modifier(SettingsPageBackground())
    }
}

/// One event's sound, as the settings page shapes it: the event's name, a
/// picker over the system's own set, and silence as a first-class answer —
/// "无声" is a choice, not an absence. A pick is heard at once, because a
/// picker of sounds that stayed quiet until the next card arrived would be
/// a picker nobody could use with their eyes closed.
private struct SoundPickerRow: View {
    let label: String
    let event: Line.SoundEvent
    weak var line: Line?

    @State private var name: String

    init(label: String, event: Line.SoundEvent, line: Line?) {
        self.label = label
        self.event = event
        self.line = line
        _name = State(initialValue: Line.soundName(for: event))
    }

    /// The set the system ships — /System/Library/Sounds — spelled out by
    /// hand, because NSSound offers no way to list them itself.
    static let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk",
                               "Glass", "Hero", "Morse", "Ping", "Pop",
                               "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Picker("", selection: $name) {
                Text(L("No sound")).tag("")
                ForEach(Self.systemSounds, id: \.self) { sound in
                    Text(sound).tag(sound)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .onChange(of: name) { _, picked in
            Line.setSound(picked, for: event)
            // The preview is the answer played back, at the volume the
            // event itself would carry. Silence needs none — it is heard
            // by nothing happening.
            guard !picked.isEmpty else { return }
            line?.play(event)
        }
    }
}
