import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    // Never key. The panel cannot take focus: a strip floating over the top
    // of the screen that became key would steal what you were typing, and no
    // amount of care afterwards gives it back convincingly.
    //
    // This is why the keys are watched globally and cannot be taken back, and
    // why they are keys nothing else uses rather than the space.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// How deep the strip is, answered by the app rather than held here.
    ///
    /// The answer is a question about what is hanging on the line right now: a
    /// note is as tall as its contents and the clipboard's cards are all one
    /// size, so the two decks want different depths. A closure rather than a
    /// stored number, so that every place the panel is put on the screen gets
    /// the depth of the deck that is up at that moment rather than the one
    /// that was up the last time somebody remembered to set it.
    ///
    /// A closure rather than a reference to the line, because the window still
    /// knows nothing about what it is a window onto — see `Layout.depth(for:)`
    /// for the number itself, which is the only place it is decided.
    var depthProvider: () -> CGFloat = { Layout.clipboardDepth }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let depth = depthProvider()
        let target = NSRect(x: visible.minX, y: visible.maxY - depth,
                            width: visible.width, height: depth)
        if frame != target { setFrame(target, display: true) }
    }
}
