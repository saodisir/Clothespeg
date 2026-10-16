import AppKit

/// Putting text where the user is working, without a drag.
///
/// An app on Chromium will not take a text drag: its official way of leaving
/// the page is `startDrag`, which carries files and nothing else, and a drop
/// into its window arrives through HTML5 — `dragover` has to be prevented
/// and then `text/plain` is read. The item offered here is exactly plain
/// text, verified, and it is still refused. So the drag is not the way in.
///
/// The way in is the one a person would use: put it on the pasteboard, go
/// back to the app, paste. That is a click on a card and nothing else, and
/// it works into a chat window, a terminal, a text field or a code editor,
/// because those all take a paste.
final class PasteInto {
    static let shared = PasteInto()

    private init() {}

    /// The app a paste would go to, or nil when there is nowhere sensible.
    ///
    /// The one in front *right now*. The line's panel is a non-activating
    /// panel (`LinePanel`), so opening it never takes the front off the app
    /// the user is working in — that app stays frontmost the whole time a
    /// card is being clicked. Reading the frontmost app at paste time, rather
    /// than tracking which app last activated, is the whole fix: activation
    /// notifications are event-driven and get missed, reordered, or
    /// overwritten by a transient grab (⌘Tab sweeping past, a notification,
    /// the Dock), which used to send the paste into the wrong window. The
    /// frontmost app is the current truth and cannot be polluted.
    ///
    /// It is also what a panel that stays open needs: the user may switch apps
    /// while it is up, and the paste should follow wherever they are.
    ///
    /// Nil when there is nothing to paste into — nothing in front, ourselves,
    /// or the Finder sitting on the bare desktop. The caller turns that into a
    /// plain copy.
    private static var target: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !isFinderOnDesktop(app) else { return nil }
        return app
    }

    /// Whether the Finder is frontmost with nothing on screen but the desktop.
    ///
    /// A click on the desktop makes the Finder frontmost, and pasting there is
    /// a paste into nothing: the desktop takes no text and is no folder to
    /// receive a file. A Finder with a real window open is left alone — a file
    /// pasted into a folder window is the one thing the desktop is not. Told
    /// apart by the Finder's on-screen windows with the desktop's own excluded.
    private static func isFinderOnDesktop(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier == "com.apple.finder" else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        let pid = app.processIdentifier
        for info in list {
            if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
                return false
            }
        }
        return true
    }

    /// Puts the payload on the pasteboard and pastes it into the app in front.
    ///
    /// The paste is a real ⌘V rather than an Apple event: every target that
    /// takes a paste takes that one, and an event would have to be aimed at
    /// one menu item on one app.
    ///
    /// Returns whether the paste was sent, so the card can say so — and so the
    /// caller can fall back to a plain copy when there was nowhere to paste.
    @discardableResult
    func paste(_ payload: Payload, rich: RichText? = nil) -> Bool {
#if APPSTORE_LITE
        // The store build cannot type into another app: the keystroke would be
        // a synthetic event posted across processes, which the sandbox forbids.
        // Saying no here makes the caller do the honest thing — copy to the
        // pasteboard and let the user press ⌘V — and the frontmost app is
        // already the one they are in, so there is nothing to bring forward.
        return false
#else
        guard Self.target != nil else { return false }

        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        switch payload {
        case .image(let url):
            if let png = Self.pngData(url) { item.setData(png, forType: .png) }
            item.setString(url.absoluteString, forType: .fileURL)
        case .file(let urls):
            // One line per file, which is what the pasteboard means by the
            // file type: a newline-separated list, not a path.
            item.setString(urls.map(\.absoluteString).joined(separator: "\n"),
                           forType: .fileURL)
        case .text(let string, _):
            guard let data = string.data(using: .utf8) else { return false }
            item.setData(data, forType: .string)
            // The formatting the copy arrived with, when it is wanted. It
            // rides on the same item as the words, so a target that takes a
            // paste takes whichever of the two it was built for.
            if FormatCopy.isEnabled, let rich { rich.write(to: item) }
        case .note(let note):
            // A note pasted somewhere goes as its lines, ticks and all. It is
            // put back as plain text rather than as anything richer, for the
            // same reason a snippet is: what a target wants characters for is
            // characters, and a note is most often going into a message or a
            // document as a list of things to do.
            guard let data = note.plainText.data(using: .utf8) else { return false }
            item.setData(data, forType: .string)
        }
        // Marked as ours for the same reason a card's own copy is: this app
        // put it here, so the watcher must not read it back as the user
        // having copied something.
        item.setString("1", forType: ClipboardWatcher.ourWrite)
        guard pb.writeObjects([item]) else { return false }

        // The app is already the one in front — that is how it was chosen, and
        // the panel that took the click is non-activating, so it stays front
        // through the gap. The pause only lets the pasteboard settle before the
        // keystroke reads it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Self.sendPaste()
        }
        return true
#endif
    }

    private static func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

#if !APPSTORE_LITE
    /// ⌘V, synthesised. The key code of V with the command flag down.
    private static func sendPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
#endif
}
