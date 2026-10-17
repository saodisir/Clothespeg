import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

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

/// The settings window: one window, five pages, and nothing else.
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
    /// Tall enough for the busiest page whole — 通用 carries the appearance,
    /// the language, the login item, the swipe and the sounds, and none of
    /// it may be cut off by the bottom edge: a setting the user has to
    /// scroll for is a setting the user does not find.
    static let size = CGSize(width: 560, height: 560)
}

/// What the window is made of.
struct SettingsView: View {
    /// The line, handed down to the page that changes what it draws.
    let line: Line?

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
        case general, invocation, keeping, permissions, about
        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: L("General")
            case .invocation: L("Invocation")
            case .keeping: L("Keeping")
            case .permissions: L("Permissions")
            case .about: L("About")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .invocation: "arrow.down.to.line"
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
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            // The track hugs the five choices; the frame centres it without
            // stretching the track behind them.
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch section {
                case .general: GeneralPage(line: line)
                case .invocation: InvocationPage()
                case .keeping: KeepingPage()
                case .permissions: PermissionsPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        // The ground for the whole window, tab strip included. The pages hide
        // the form background themselves; the strip above them answered to
        // the window's grey, and in light mode that grey against the pages'
        // white read as two windows in one. Now the CDS warm ground — the
        // same reasoning the white answered, warmed to match the paper the
        // rest of the app wears.
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

            Section {
                Toggle(L("Sounds"), isOn: $soundOn)
                    .disabled(line == nil)
            }


            // The one clipboard behaviour that is a choice rather than a
            // fact. The footer is the map of how a copy goes out — which
            // gesture asks this switch and which answers to nobody — and it
            // changes with the switch, because the answer is different on
            // each side of it.
            Section {
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

                // The folders the user asked to watch. The headline row
                // carries the add button, the folders it has follow, and the
                // promise comes last: the button is what the eye is here
                // for, the words are for the moment after.
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
            .onChange(of: imageFilesAsPictures) { _, on in
                ImageFileHanging.isEnabled = on
            }
            .onChange(of: imageFileLimitText) { _, text in
                if let mb = Self.parsedLimit(text) {
                    ImageFileHanging.limitMB = mb
                }
            }
            .onAppear(perform: refreshFolderRows)
        }
        .formStyle(.grouped).settingsPageBackground()
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
                Text(L("Click one, then press the new combination. Esc cancels."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The two that act on a line already down. A separate card because
            // they answer under a different rule: these work only while the
            // line is down — and only while Clothespeg is not frontmost — so a
            // plain letter is safe here in a way it never is for the two
            // above. The button on the rope and the key that does the same
            // thing from the keyboard are grouped, because they are one action
            // reached two ways.
            Section {
                Text(L("While the line is down"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // New note: the button on the rope and its key, together.
                Toggle(L("Show the new note button"), isOn: $showNoteMark)
                LabeledContent(L("New note shortcut")) {
                    HotkeyRecorder(door: .note, requiresModifier: false)
                }

                // Keep-down: the prop button on the rope and its key, together.
                Toggle(L("Show the lock button"), isOn: $showPropMark)
                LabeledContent(L("Lock the rope shortcut")) {
                    HotkeyRecorder(door: .prop, requiresModifier: false)
                }

                // One paragraph, small and grey: what these keys are for, the
                // one place they stand down, and that Esc dismisses a propped
                // line from anywhere.
                Text(L("These keys work while the line is down, wherever the pointer is. They stand down while Clothespeg itself is frontmost, so they cannot eat what you type into it; they work whether or not the buttons are shown, and a propped line is put away with Esc from anywhere."))
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
        .formStyle(.grouped).settingsPageBackground()
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .formStyle(.grouped).settingsPageBackground()
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
            .formStyle(.grouped).settingsPageBackground()
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
                Text(L("It is used for one thing: pressing ⌘V in the app you came from, so a click on a card lands where you were typing. Nothing is read and nothing is recorded."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(granted
                     ? L("Granted. Clicking a card puts it where you are working.")
                     : L("Not granted. Clicking a card still copies it, but you have to paste it yourself."))
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
                Text(L("Based on Tendedero"))
                    .font(.system(size: 12, weight: .medium))
                Text(L("by Alejandro Buján, used under the MIT License. This fork is Apache-2.0."))
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
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
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
        content
            .scrollContentBackground(.hidden)
            .background(CDS.ground)
    }
}

private extension View {
    func settingsPageBackground() -> some View {
        modifier(SettingsPageBackground())
    }
}
