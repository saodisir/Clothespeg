import AppKit

/// Where the pointer has to rest for the line to come down.
///
/// It used to be the whole menu bar: a band six hundred points wide, every
/// point of which belongs to some other program. Resting on the pointer
/// anywhere along it opened a line of cards over a menu you were reading,
/// which is a thing that has to be waited out rather than a thing that was
/// meant.
///
/// The notch is the one part of the top edge that belongs to nothing. It is
/// the same gesture — push up against the top of the screen — aimed at a
/// smaller place, so the line comes down when you reach for it and not when
/// you reach for a menu.
///
/// The system does not hand the notch over directly, but it does say where
/// the notch is not: the two areas it reserves at the top of the screen, left
/// and right of the camera. What is between them is the notch. On a fourteen
/// inch MacBook that is the five hundred and eighty-five points of nothing
/// between the menu bar's left piece and its right one.
///
/// A screen with no notch in it has no such gap, and there the whole menu bar
/// is still the answer: an external display has to be able to bring the line
/// down too, and there is nothing else on its top edge to aim at.
enum TriggerBand {

    /// Whether this machine has a notch to aim at, which decides what the
    /// setting that opens the line calls itself. A display without one is
    /// not a failure, it is just somewhere the menu bar is still the answer.
    static var hasNotch: Bool {
        NSScreen.screens.contains { notch(of: $0) != nil }
    }

    /// The strip at the top of that screen where the pointer rests to bring
    /// the line down. Nil when the pointer is nowhere near it.
    static func contains(_ mouse: NSPoint, on screen: NSScreen) -> Bool {
        NSMouseInRect(mouse, band(of: screen), false)
    }

    static func band(of screen: NSScreen) -> NSRect {
        if let notch = notch(of: screen) { return notch }
        return menuBar(of: screen)
    }

    /// The notch itself, or nil on a screen without one.
    ///
    /// Both auxiliary areas are needed: a screen where only one is reported
    /// is a screen where the notch is somewhere off to one side, and treating
    /// the rest of the menu bar as notch would open the line from the middle
    /// of nowhere.
    static func notch(of screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              // A gap narrower than this is not a notch, it is two menu bar
              // pieces that meet, and a trigger a few points wide is one you
              // cannot hit on purpose.
              right.minX - left.maxX > 60 else { return nil }

        // The area between the two, but the full height of the top strip
        // rather than the height of the pieces beside it: the notch reaches
        // all the way to the edge of the screen and so must the band, or the
        // line opens only when the pointer is a couple of points too low.
        return NSRect(x: left.maxX,
                      y: screen.frame.maxY - topStripHeight(of: screen),
                      width: right.minX - left.maxX,
                      height: topStripHeight(of: screen))
    }

    /// The whole menu bar strip, for a screen with no notch to aim at.
    static func menuBar(of screen: NSScreen) -> NSRect {
        let h = topStripHeight(of: screen)
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h,
                      width: screen.frame.width, height: h)
    }

    /// How tall the top strip of that screen is: the menu bar, or the notch
    /// where it is deeper than the bar. With an auto-hiding menu bar the
    /// visible frame reaches the top, so the gap is zero and the system
    /// thickness is what is left to go on.
    private static func topStripHeight(of screen: NSScreen) -> CGFloat {
        let gap = screen.frame.maxY - screen.visibleFrame.maxY
        if gap >= 1 { return gap }
        return max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
    }
}

/// The deck the resting gesture brings down.
///
/// One choice made first, in the settings: which kind of door this is.
/// Two, and they are alternatives rather than a stack, because a door you
/// configure once should not also ask for a key every time:
///
/// - **Halves.** The notch is wide enough to be two doors, one deck on each
///   side, and which deck sits on which side is the setting. No key to hold,
///   nothing to remember beyond where you already are.
/// - **A modifier key.** A default deck, and the chosen key brings the other
///   one. The shape for a screen without a notch, whose band is the whole
///   menu bar and cannot be cut in two — every point of it belongs to some
///   other program.
enum DropDeck {

    /// Which kind of door the resting gesture is.
    enum Style: String, CaseIterable {
        case halves, modifier
    }

    /// The chosen door. A modifier key by default: it is the one shape that
    /// works on every screen, notched or not — halves need a notch to cut in
    /// two, and a machine without one (or a window on an external display)
    /// would meet a whole menu bar that cannot be. Notch owners switch to
    /// halves in the settings, where the notch is what the picture shows.
    static var style: Style {
        get { Style(rawValue: UserDefaults.standard.string(forKey: "invokeStyle") ?? "") ?? .modifier }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "invokeStyle") }
    }

    /// The deck on each half of the notch, in halves mode. Read as the
    /// default on a screen without a notch, where there are no halves.
    static var left: Line.Deck { deck("dropDeckLeft", .clipboard) }
    static var right: Line.Deck { deck("dropDeckRight", .notes) }

    /// The deck the gesture brings down before the flip key is considered,
    /// in modifier mode.
    static var defaultDeck: Line.Deck { deck("dropDeckDefault", .clipboard) }

    private static func deck(_ key: String, _ fallback: Line.Deck) -> Line.Deck {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let stored = Line.Deck(rawValue: raw) else { return fallback }
        return stored
    }

    static func setDeck(_ value: Line.Deck, forKey key: String) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }

    /// The key that, held while the pointer rests, brings the other deck.
    /// Modifier mode only — in halves mode the position has already said
    /// which deck, and a key on top of it would be a second answer to a
    /// question that was asked once.
    enum Flip: String, CaseIterable {
        case none, option, control, command, shift

        var flags: NSEvent.ModifierFlags? {
            switch self {
            case .none: nil
            case .option: .option
            case .control: .control
            case .command: .command
            case .shift: .shift
            }
        }

        var label: String {
            switch self {
            case .none: L("None")
            case .option: "⌥ Option"
            case .control: "⌃ Control"
            case .command: "⌘ Command"
            case .shift: "⇧ Shift"
            }
        }
    }

    /// The chosen flip key. Option, until somebody says otherwise: it is the
    /// one modifier that is nobody's shortcut prefix on its own.
    static var flip: Flip {
        get { Flip(rawValue: UserDefaults.standard.string(forKey: "deckFlipModifier") ?? "") ?? .option }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deckFlipModifier") }
    }

    /// How long the pointer has to rest before the line comes down. A taste
    /// with real spread: a flick of a hand wants it fast, a crowded menu bar
    /// wants it slow. The notch gesture and the whole-bar gesture on a screen
    /// without one wait the same, because one speed to learn is enough.
    enum Rest: String, CaseIterable {
        case sensitive, standard, relaxed

        var seconds: TimeInterval {
            switch self {
            case .sensitive: 0.15
            case .standard: 0.25
            case .relaxed: 0.4
            }
        }

        var label: String {
            switch self {
            case .sensitive: L("Sensitive")
            case .standard: L("Standard")
            case .relaxed: L("Relaxed")
            }
        }
    }

    static var rest: Rest {
        get { Rest(rawValue: UserDefaults.standard.string(forKey: "restDelay") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "restDelay") }
    }

    /// The deck the pointer resting on this screen is asking for.
    static func at(_ mouse: NSPoint, on screen: NSScreen) -> Line.Deck {
        if style == .halves, TriggerBand.notch(of: screen) != nil {
            return mouse.x < TriggerBand.band(of: screen).midX ? left : right
        }
        let base = defaultDeck
        if let flags = flip.flags, NSEvent.modifierFlags.contains(flags) {
            return base == .clipboard ? .notes : .clipboard
        }
        return base
    }
}