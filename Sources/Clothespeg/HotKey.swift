import AppKit
import Carbon

/// A single global shortcut through the Carbon hot key API. Unlike a global
/// key monitor, it needs no Accessibility permission.
///
/// Each one carries its own action and its own id.
///
/// It used to keep the action in a `static`, which was right while there was
/// one shortcut and silently wrong the moment there were two. Every instance
/// installs a handler on the application, every handler fires for every hot
/// key, and all of them called the same last-set action — so the second
/// shortcut would do the first one's work, twice, and never do its own. The
/// key an event belongs to is in the event, so it is read there.
final class HotKey {
    private var ref: EventHotKeyRef?
    /// The handler this key installed, kept so it can be taken off again.
    /// Left installed over a deallocated key, it would read freed memory the
    /// next time any shortcut in the app was pressed.
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void
    /// What this key was asked for, kept so a refusal can be logged with the
    /// combination it was about rather than a bare status code.
    private(set) var keyCode: Int
    private(set) var modifiers: Int

    /// What the two Carbon calls answered. Both are read rather than trusted,
    /// because a refused registration is a shortcut that is silently dead:
    /// `RegisterEventHotKey` says `eventHotKeyExistsErr` when anything else —
    /// another copy of this app, another app, the system — already holds the
    /// same combination, and a caller that ignores the answer never learns
    /// that the key it just "registered" answers to nobody. Kept on the
    /// instance so the caller can put both in the diagnostics log.
    private(set) var installStatus: OSStatus = noErr
    private(set) var registerStatus: OSStatus = noErr

    init(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let box = Unmanaged.passUnretained(self).toOpaque()
        installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            // Everything that is not this key's own event answers
            // `eventNotHandledErr`, which is the whole of why there is more
            // than one shortcut working at a time.
            //
            // The application's handlers are a chain, they are called newest
            // first, and the first one to return anything else ends it — so
            // answering `noErr` about a key that is not yours tells the
            // dispatcher the key was dealt with and the handler that owns it
            // is never asked. With three shortcuts that is not a subtle bug:
            // the last one registered answers for all of them and the other
            // two appear not to be registered at all, which is exactly what
            // it looks like — a shortcut that does nothing when you press it.
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let key = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Only the key this handler was installed for. Without this every
            // shortcut in the app would answer for every other one.
            guard pressed.id == key.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { key.action() }
            return noErr
        }, 1, &spec, box, &handler)

        // "CLSG", the same signature for all of them: the id is what tells
        // them apart.
        let hotID = EventHotKeyID(signature: OSType(0x434C_5347), id: id)
        registerStatus = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotID,
                                             GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// The four doors, and the shortcut each one answers to.
///
/// A choice made in the settings, one recorder per door: what is stored is
/// what the recorder caught — the key code, the Carbon modifiers the hot key
/// API speaks, and the character the key wears, which is what the menu writes
/// beside the door's name. ⌃⌥C and ⌃⌥N until somebody says otherwise.
///
/// Two kinds of door, and the difference is where they are heard. `clipboard`
/// and `notes` bring the line down from anywhere, so they are registered as
/// real global hot keys through Carbon — the right tool, because it needs no
/// Accessibility permission and it answers whether or not this app is front.
/// `note` and `prop` act on a line that is already down. They are bare
/// letters, and a bare letter registered for good would eat that letter in
/// whatever app the user was typing in, so they are registered as real hot
/// keys only while the line is down and this app is not the frontmost one,
/// and unregistered again the moment either stops being true — see
/// `AppDelegate.updatePanelKeys`.
enum Door: String, CaseIterable {
    case clipboard, notes, note, prop

    /// Whether this door brings the line down (a real global hot key) or acts
    /// on a line that is already down (answered only while the line is down).
    var isSummon: Bool { self == .clipboard || self == .notes }

    /// The doors a Carbon registration covers.
    static var summonDoors: [Door] { [.clipboard, .notes] }

    /// The doors the panel answers while it is down, in the order the settings
    /// offer them.
    static var panelDoors: [Door] { [.note, .prop] }

    var keyCode: Int {
        get { UserDefaults.standard.object(forKey: "hotkey.\(rawValue).code") as? Int ?? defaultCode }
        set { UserDefaults.standard.set(newValue, forKey: "hotkey.\(rawValue).code") }
    }

    var carbonModifiers: Int {
        get { UserDefaults.standard.object(forKey: "hotkey.\(rawValue).mods") as? Int ?? defaultModifiers }
        set { UserDefaults.standard.set(newValue, forKey: "hotkey.\(rawValue).mods") }
    }

    /// Whether a key is recorded. A door with no key wears a dash in the
    /// recorder and is registered nowhere — no registration path ever hands
    /// Carbon a -1 (see `AppDelegate.registerHotkeys` and `updatePanelKeys`),
    /// and that refusal is exactly what makes emptying a door safe.
    var isSet: Bool { keyCode >= 0 }

    /// Empties the door, leaving it with no key — the way a shortcut is
    /// turned off without being given a different one. -1 is the marker for
    /// "no key": no real key wears it, so nothing ever matches it, and every
    /// path that registers a door checks `isSet` first.
    func clear() {
        set(code: -1, modifiers: 0, character: "")
    }

    /// The character the key wears, for the menu and the recorder's label.
    var displayCharacter: String {
        get { UserDefaults.standard.string(forKey: "hotkey.\(rawValue).char") ?? defaultCharacter }
        set { UserDefaults.standard.set(newValue, forKey: "hotkey.\(rawValue).char") }
    }

    var defaultCode: Int {
        switch self {
        case .clipboard: kVK_ANSI_C
        case .notes: kVK_ANSI_N
        case .note: kVK_ANSI_N
        case .prop: kVK_ANSI_D
        }
    }

    var defaultCharacter: String {
        switch self {
        case .clipboard: "C"
        case .notes: "N"
        case .note: "N"
        case .prop: "D"
        }
    }

    /// The two summons keep ⌃⌥ so they never eat an ordinary letter. The two
    /// that act on a line already down answer only while that line is down,
    /// which is a state the user put the app into on purpose and takes it out
    /// of again — so they default to the bare letter rather than a
    /// combination nobody would press on purpose. The price is that the
    /// letter belongs to the line for as long as the line is down.
    var defaultModifiers: Int { isSummon ? (controlKey | optionKey) : 0 }

    func set(code: Int, modifiers: Int, character: String) {
        UserDefaults.standard.set(code, forKey: "hotkey.\(rawValue).code")
        UserDefaults.standard.set(modifiers, forKey: "hotkey.\(rawValue).mods")
        UserDefaults.standard.set(character, forKey: "hotkey.\(rawValue).char")
    }

    /// Carbon modifiers, as the menu wants them.
    var nsModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & controlKey != 0 { flags.insert(.control) }
        if carbonModifiers & optionKey != 0 { flags.insert(.option) }
        if carbonModifiers & shiftKey != 0 { flags.insert(.shift) }
        if carbonModifiers & cmdKey != 0 { flags.insert(.command) }
        return flags
    }

    /// The prefix the menu would draw: ⌃⌥⇧⌘, in that order, then the key.
    var display: String {
        var out = ""
        if carbonModifiers & controlKey != 0 { out += "⌃" }
        if carbonModifiers & optionKey != 0 { out += "⌥" }
        if carbonModifiers & shiftKey != 0 { out += "⇧" }
        if carbonModifiers & cmdKey != 0 { out += "⌘" }
        return out + displayCharacter.uppercased()
    }

    /// `display`, or a dash when no key is recorded — what the recorder shows
    /// beside a door that has been cleared.
    var displayOrNone: String { isSet ? display : "—" }

    /// NSEvent modifiers, as the recorder catches them, into Carbon's.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var out = 0
        if flags.contains(.control) { out |= controlKey }
        if flags.contains(.option) { out |= optionKey }
        if flags.contains(.shift) { out |= shiftKey }
        if flags.contains(.command) { out |= cmdKey }
        return out
    }
}
