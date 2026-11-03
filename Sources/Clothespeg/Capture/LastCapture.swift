import AppKit

/// What the last capture was: the frame, and what the frame was for.
///
/// The rectangle is the thing that comes back — the button puts it on the screen
/// and lets the person decide again. The type rides along because it costs one
/// field and answers "what was that area for" in the log; it deliberately does
/// not choose anything on the person's behalf, since the whole point of putting
/// the frame back is that the next move is theirs.
///
/// Kept in the defaults rather than in memory, because the case this is for is
/// "that same panel again, a while later", and a relaunch in between is ordinary.
/// Small, and read once per capture rather than per frame.
struct LastCapture: Codable {
    /// The kinds the capture can end in. Six, and the two reading ones are on
    /// the list for the same reason the picture ones are: choosing 识别 or 译 is
    /// a decision about *what this area is*, and it stays true of that area
    /// after the window is gone — worth knowing, worth logging, not worth
    /// pressing on someone's behalf.
    enum Kind: String, Codable {
        /// A region, as a picture.
        case area
        /// A window, photographed from its own surface.
        case window
        /// The whole of one display.
        case screen
        /// A region that kept growing as the page scrolled.
        case long
        /// A region read as text.
        case words
        /// A region read and put into the other language.
        case translate
    }

    var kind: Kind
    /// In AppKit's screen coordinates: bottom left of the main display, y up —
    /// the same space everything else in this feature speaks.
    var rect: CGRect
    /// The window, for the one kind that photographs a window on its own. Nil
    /// for the rest, and nil is also the honest answer for a window kind that
    /// was stored before there was an id to store.
    var windowID: UInt32?

    static let defaultsKey = "lastCapture"

    /// The last capture, or nil when there has never been one.
    ///
    /// A decode failure is treated as nil rather than as an error: the only way
    /// to get one is a stored value from an older build, and the right answer
    /// to that is a button that does not appear rather than a button that
    /// throws when pressed.
    static var stored: LastCapture? {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
            return try? JSONDecoder().decode(LastCapture.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                return
            }
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Remembers a capture that just landed.
    ///
    /// Called from the places that land one and nowhere else: a capture that
    /// was drawn and abandoned is not something "again" should mean, and the
    /// rectangle a person cancels is exactly the one they were trying to get
    /// away from.
    static func remember(_ kind: Kind, _ rect: CGRect, window: UInt32? = nil) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        stored = LastCapture(kind: kind, rect: rect, windowID: window)
    }
}
