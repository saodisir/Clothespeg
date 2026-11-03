import AppKit

/// The one window of a long capture that still takes a click.
///
/// While a long capture runs the overlay ignores the mouse on purpose: the wheel
/// has to reach the app being scrolled, and so do the clicks — a page that
/// cannot be clicked cannot be expanded, and expanding things is half of what
/// scrolling a page is for. The first version paid that price without noticing
/// the second half of it: the bar was drawn by the overlay, so anything on that
/// bar pressing-shaped would have been a picture of a button.
///
/// So the bar gets a window of its own, laid exactly over the capsule and drawn
/// by nobody. It stays invisible, takes the click, and hands it to the pill the
/// overlay is already drawing underneath. One bar, one picture: a panel with its
/// own rendering would be a second copy of the bar, and the second copy is the
/// one that goes out of date.
///
/// It also reports where the pointer is, which is the only report of that kind
/// while a long capture runs — a window that ignores the mouse does not hear the
/// pointer move. Both things the surface does with it (lighting the pill, and
/// deciding whether to take presses itself) are its own arithmetic, so the point
/// is passed on raw rather than interpreted here.
@MainActor
final class LongBarPanel: NSPanel {
    /// The Done pill was pressed.
    var onDone: () -> Void = {}
    /// The ✕ was pressed: leave without a picture.
    var onClose: () -> Void = {}
    /// Where the pointer is, in screen coordinates, or nil once it has left the
    /// bar. Screen coordinates because that is the one space both windows share:
    /// the bar's window and the overlay are laid over the same screen.
    var onPointer: (NSPoint?) -> Void = { _ in }

    /// - Parameters:
    ///   - capsule: the whole bar, in screen coordinates. The window is this
    ///     rectangle: everything in it is the capture's, so a press on the
    ///     number or the words is spent rather than falling through to the page
    ///     underneath.
    ///   - done: the pill inside it, in screen coordinates.
    ///   - close: the ✕ beside it, in screen coordinates.
    init(capsule: NSRect, done: NSRect, close: NSRect) {
        super.init(contentRect: capsule,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        // Not fully clear, and this is the whole reason the button ignored its
        // clicks for a while. A window with nothing in it — clear background, no
        // content, not one opaque pixel — is a window the window server can see
        // through, and it does not hand it presses. That matches what was
        // measured: the pointer crossed the pill (`NSTrackingArea`, which is
        // window-server work) while `mouseDown`, which is application work, never
        // ran, on a window that was topmost at that exact pixel.
        //
        // Two percent of black over the bar is invisible and is enough to make
        // the window real. The bar itself is still drawn by the overlay
        // underneath, so nothing is drawn twice.
        backgroundColor = NSColor.black.withAlphaComponent(0.02)
        hasShadow = false
        // A panel is allowed to hide itself when its app stops being front. This
        // one exists only while the app is *not* front, so the default would
        // close it at precisely the moment it is needed.
        hidesOnDeactivate = false
        // Never actually takes the keyboard: the panel only becomes key if
        // something inside it needs one, and the bar has nothing that does. This
        // flag is what makes "can become key" harmless instead of a focus grab.
        becomesKeyOnlyIfNeeded = true
        // Where the pointer is gets reported by tracking areas, and tracking
        // areas only see movement that the window is told about.
        acceptsMouseMovedEvents = true
        // ARC owns this window. Without it the remove in the controller would be
        // followed by an over-release, which is the kind of crash that looks
        // like a random one.
        isReleasedWhenClosed = false
        // One step above the overlay it belongs to, and no higher.
        level = CaptureLevels.button
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = LongBarHost(frame: NSRect(origin: .zero, size: capsule.size),
                               pill: done.offsetBy(dx: -capsule.minX, dy: -capsule.minY),
                               close: close.offsetBy(dx: -capsule.minX, dy: -capsule.minY))
        host.onDone = { [weak self] in self?.onDone() }
        host.onClose = { [weak self] in self?.onClose() }
        host.onPointer = { [weak self] in self?.onPointer($0) }
        contentView = host
    }

    /// A borderless window refuses the keyboard by default. Allowed here, and
    /// with the caveat that it never actually takes it: `becomesKeyOnlyIfNeeded`
    /// means the panel only becomes key if something inside it needs the
    /// keyboard, and the bar has nothing that does. What it buys is a window
    /// AppKit treats as an ordinary clickable one rather than a decoration.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Decides whether a press landed on the pill, and says where the pointer is.
private final class LongBarHost: NSView {
    private let pill: NSRect
    private let close: NSRect
    var onDone: () -> Void = {}
    var onClose: () -> Void = {}
    var onPointer: (NSPoint?) -> Void = { _ in }
    private var area: NSTrackingArea?
    private var onPill = false

    init(frame: NSRect, pill: NSRect, close: NSRect) {
        self.pill = pill
        self.close = close
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The first click in a window that is not key still belongs to it. Without
    /// this the press meant for the button is spent waking the window up, and
    /// the person presses again — which reads as a button that only works on
    /// the second try.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        // The whole bar, not just the pill. With only the pill tracked, sliding
        // off it is silence: no exit, no enter, and a ring left lit over a
        // button the pointer is no longer on. Tracked this way, every step
        // reports, and the surface decides which side of the edge it was.
        let fresh = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                   owner: self,
                                   userInfo: nil)
        addTrackingArea(fresh)
        area = fresh
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }

    override func mouseExited(with event: NSEvent) {
        note(onPill: false)
        onPointer(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Logged before the decision. "The button does nothing" has two causes
        // that look identical afterwards — a press that never arrived, and a
        // press that arrived beside the pill — and only a line down here tells
        // them apart.
        diagLog("Capture long: press at \(Int(point.x)),\(Int(point.y)), pill "
            + "\(Int(pill.minX))…\(Int(pill.maxX))×\(Int(pill.minY))…\(Int(pill.maxY)), ✕ "
            + "\(Int(close.minX))…\(Int(close.maxX))×\(Int(close.minY))…\(Int(close.maxY))")
        // Pressed rather than released. There is no drag on a pill that ends the
        // capture, and acting on the press means the mode is over before the
        // hand starts moving again.
        //
        // The ✕ is asked first: it is the smaller target of the two and it sits
        // beside the pill, so a press that is a point or two off the exit must
        // not end up finishing the capture instead.
        if close.contains(point) {
            diagLog("Capture long: ✕ pressed")
            onClose()
            return
        }
        guard pill.contains(point) else { return }
        onDone()
    }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        note(onPill: pill.contains(point))
        guard let window else { return }
        onPointer(window.convertPoint(toScreen: event.locationInWindow))
    }

    private func note(onPill value: Bool) {
        guard onPill != value else { return }
        onPill = value
        // The other half of "the click did nothing": this fires on a pointer
        // merely crossing the pill, with no button involved. If the pointer
        // crosses and nothing is logged, the window is not receiving input at
        // all, which is a different repair from a click that lands beside the
        // target.
        diagLog("Capture long: pointer \(value ? "on" : "off") the pill")
    }
}
