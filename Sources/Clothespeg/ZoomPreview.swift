import SwiftUI
import AppKit
import Quartz
import QuickLookUI

/// Reading a card properly, without changing the line.
///
/// A card is 150pt wide because a screen fits eleven of them. That is the
/// right size for a picture and the wrong one for a snippet: a line of code
/// at 10pt is thirty-odd characters, and the difference between the first
/// card and the fifth is often a bracket.
///
/// The zoom is a separate window rather than a bigger card, deliberately.
/// Making the card itself grow would push its neighbours along the line,
/// and the whole point is that the line stays where it was while one card is
/// read. It is also the only way to show more without the line rearranging
/// under the pointer.
struct ZoomPreview {
    /// Where it is showing, and what the user was looking at.
    var payload: Payload
    var origin: Origin
    /// Below the card that opened it, in that card's own coordinates.
    var anchor: NSPoint
    /// What a code in the picture says, when it holds one. Nil for every
    /// card that is not a picture holding a code, which is nearly all of
    /// them.
    var qrcodes: [String]?

    /// One size for every kind of card.
    ///
    /// The window is the same whatever is in it, so the reader learns where
    /// to look and a window that changes shape between a note and a picture
    /// reads as two different things rather than the same one. Roughly four
    /// times a card in each direction: enough for a screenshot to be read at
    /// its own resolution and for a line of code to lose its truncation, and
    /// small enough to stay on the screen with room around it.
    static let size = CGSize(width: 640, height: 440)

    /// The smallest a pinned window can be dragged to.
    ///
    /// A floor for reading, not a limit of the layout. It was 320×220, which
    /// kept forty characters of code on a line; the ask was for something
    /// smaller, and 280×180 still fits about thirty and still leaves room for
    /// the pin and the slider across the top. Anything smaller is a window
    /// that has stopped being able to answer the question it was opened for.
    static let minimumSize = CGSize(width: 280, height: 180)

    /// Kept for the callers that want to know it without the type; the size
    /// is the same either way.
    var size: CGSize { Self.size }
}

/// The window the zoom opens in.
///
/// A borderless panel that takes no focus: pressing space again, or
/// clicking anywhere, dismisses it, and the app the user was in never
/// changes. A reader that stole the key window would need a second click
/// to get back to work, which is worse than the small card was.
///
/// It does take the mouse, and that is a change worth recording. The first
/// version took nothing at all — `ignoresMouseEvents = true` — which made
/// every click here a dismiss and looked like the simplest possible reader.
/// What it also did was hand the wheel to the app underneath: scroll events
/// are delivered by hit testing, and a window that refuses the mouse is not
/// in the hit test, so a long snippet opened at size could not be scrolled
/// by a trackpad or by the scroll bar that was drawn down its right side.
/// Reading a long thing is the whole reason this window exists, so it takes
/// the mouse and pays for it by telling a click from a drag: a press that
/// moved is a scroll bar being dragged or a selection being made, and a press
/// that did not is still a click, which still dismisses.
final class ZoomWindow: NSPanel {
    /// What a press means once it is known to have been a press rather than
    /// the beginning of a drag.
    var onPress: (() -> Void)?
    /// Where the current press started, in window coordinates. Nil between
    /// presses, and the distance from here is what tells the two apart.
    private var pressedAt: NSPoint?
    /// A move in flight: where the hand was when it started, in screen
    /// coordinates, and where the window stood at that moment.
    private var moveFrom: NSPoint?
    private var moveOrigin: NSPoint?
    /// A resize in flight, on the same terms.
    private var resizeEdge: Edge?
    private var resizeFrom: NSPoint?
    private var resizeFrame: NSRect?
    /// The controls drawn inside the window — the pin, and whatever joins it.
    ///
    /// A press that lands on one of these is a press on a control rather than
    /// the "click anywhere" that puts a glance away. The window sorts the two
    /// out before it decides anything, because a button that dismisses the
    /// window it is drawn in is not a button.
    var controls: [NSView] = []
    /// Whether the window is being held open. Read by the controller, which
    /// is the only thing that changes it.
    private(set) var isPinned = false

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = false
        // The cursor is set from mouse moves, and a window that does not
        // accept them never hears one: the card would keep whatever cursor
        // the pointer arrived with.
        acceptsMouseMovedEvents = true
        contentView = content
        WindowPrivacy.apply(to: self)
    }

    /// Whether the window may be made key. False at birth; true only while
    /// pinned.
    ///
    /// Keyboard input needs a window to land in. Once the app is frontmost, a
    /// window that cannot take the key would swallow every keystroke the user
    /// meant for the app they were in — so the pinned window takes the key,
    /// and only the pinned one. Pinning is the one moment the user has said
    /// "I am working in this window". `.nonactivatingPanel` stays in the style
    /// mask all the same: the front is taken on purpose, not by a click on the
    /// panel.
    var keyable = false

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    /// Holds the window open, or lets it go back to being a glance.
    ///
    /// Pinning changes exactly two things and nothing about how the window
    /// draws: the style mask grows `.resizable`, so the edges can be dragged,
    /// and the canvas stops closing on a click. The second half is the
    /// controller's to do, because the click that puts a glance away is
    /// watched for from outside this class as well.
    ///
    /// `.resizable` is added here rather than set at birth because an
    /// unpinned glance must not be draggable: it is 640×440 for a reason, and
    /// a window that can be resized but springs back on the next open is a
    /// window that lied about what it was.
    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        if pinned {
            styleMask.insert(.resizable)
            minSize = ZoomPreview.minimumSize
            // Semantically true, and relied on by nothing: the move itself is
            // done in `sendEvent`, because AppKit's background drag does not
            // reach a borderless panel. The refinement is switched off so
            // there is only ever one thing moving the window.
            isMovable = true
            isMovableByWindowBackground = false
            keyable = true
        } else {
            styleMask.remove(.resizable)
            minSize = .zero
            isMovable = false
            isMovableByWindowBackground = false
            keyable = false
        }
    }

    /// Whether a release is a click, decided by how far the press travelled.
    ///
    /// Three points, which is the same order as the slop AppKit uses to call
    /// a press a drag: enough that a hand resting on a trackpad while it
    /// rolls does not turn a scroll into a dismiss, and small enough that a
    /// deliberate click never reads as a drag.
    private static let clickSlop: CGFloat = 3

    /// Whether a press is currently dragging an edge or the paper.
    ///
    /// Asked by the cursor, which has no business rewriting itself while the
    /// hand is busy: an open hand under a move in flight, or a resize arrow
    /// under an edge that is already being pulled, is a cursor arguing with
    /// the gesture that owns it.
    var isHoldingWindow: Bool { resizeEdge != nil || moveFrom != nil }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A press on a control is not a press on the window. Recorded as
            // no press at all, so the release cannot be read as a click and
            // the glance does not close under the hand that just pinned it.
            if isPressOnControl(event) {
                pressedAt = nil
            } else if let edge = edge(at: event.locationInWindow) {
                pressedAt = nil
                resizeEdge = edge
                resizeFrom = convertPoint(toScreen: event.locationInWindow)
                resizeFrame = frame
                return
            } else if canStartMove(with: event) {
                pressedAt = nil
                // Taken from the event rather than from `NSEvent.mouseLocation`
                // so that the move can be rehearsed offscreen: a synthetic
                // event says where it is, the real cursor says nothing.
                moveFrom = convertPoint(toScreen: event.locationInWindow)
                moveOrigin = frame.origin
                NSCursor.closedHand.set()
                // Not passed on: the press is the window's, and the card
                // underneath should not begin a selection under a hand that
                // is moving the window.
                return
            } else {
                pressedAt = event.locationInWindow
            }
        case .leftMouseDragged:
            if let edge = resizeEdge, let from = resizeFrom, let start = resizeFrame {
                let now = convertPoint(toScreen: event.locationInWindow)
                setFrame(resized(start, edge: edge,
                                 by: NSSize(width: now.x - from.x, height: now.y - from.y)),
                         display: true)
                return
            }
            if let from = moveFrom, let origin = moveOrigin {
                let now = convertPoint(toScreen: event.locationInWindow)
                setFrameOrigin(clamped(NSPoint(x: origin.x + now.x - from.x,
                                               y: origin.y + now.y - from.y)))
                return
            }
        case .leftMouseUp:
            // The end of a move is not a click: nothing is dismissed, and the
            // release is swallowed so the card does not see a click it never
            // had a press for.
            if resizeEdge != nil {
                resizeEdge = nil
                resizeFrom = nil
                resizeFrame = nil
                applyCursor(for: event.locationInWindow)
                return
            }
            if moveFrom != nil {
                moveFrom = nil
                moveOrigin = nil
                // The hand opens again, and the paper says so.
                applyCursor(for: event.locationInWindow)
                return
            }
            let origin = pressedAt
            pressedAt = nil
            if let origin,
               hypot(event.locationInWindow.x - origin.x,
                     event.locationInWindow.y - origin.y) < Self.clickSlop {
                // Out of this call rather than inside it: the press and the
                // release are still being delivered to the scroll view, and
                // taking the window away mid-delivery is the sort of thing
                // that works until the day it does not.
                DispatchQueue.main.async { [weak self] in self?.onPress?() }
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Whether this press begins a move of the window.
    ///
    /// Asked of the view hierarchy rather than by keeping a rectangle: a
    /// rectangle would have to be recomputed on every resize and would drift
    /// from where things actually are the first time either moved. A text
    /// field answers no, so a drag across a paragraph still selects it; the
    /// paper and a picture answer yes, so a drag there moves the window.
    ///
    /// The move is done here, by hand, rather than by `isMovable` and
    /// `isMovableByWindowBackground`. Those were set, checked, and left the
    /// window nailed down: a borderless panel has no title bar for AppKit's
    /// window-drag to hang from, and the documented flags turned out to be
    /// only as good as the machinery behind them. Setting the frame directly
    /// has nothing to be defeated by.
    private func canStartMove(with event: NSEvent) -> Bool {
        guard isPinned, !isPressOnControl(event),
              let hit = contentView?.hitTest(event.locationInWindow) else { return false }
        return hit.mouseDownCanMoveWindow
    }

    /// Which edge or corner a press landed on, if any.
    ///
    /// Eight points, the same band AppKit gives a titled window's edge. The
    /// band exists because `.resizable` on a borderless panel is a promise
    /// AppKit does not keep: there is no frame for its resize machinery to
    /// live on, so the window says it can be resized and then ignores every
    /// drag on its edge. The corner arcs are 16pt, so the band sits inside
    /// the paper rather than in the rounded-away corner.
    enum Edge {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight

        /// Spoken in the log, so a cursor that stayed put can be traced back to
        /// the edge it was supposed to be offering.
        var name: String {
            switch self {
            case .left: return "left"
            case .right: return "right"
            case .top: return "top"
            case .bottom: return "bottom"
            case .topLeft: return "top left"
            case .topRight: return "top right"
            case .bottomLeft: return "bottom left"
            case .bottomRight: return "bottom right"
            }
        }
    }

    /// The band, in points from the window's edge.
    static let edgeBand: CGFloat = 8

    func edge(at point: NSPoint) -> Edge? {
        // Only a pinned window has edges to grab. A glance is 640×440 by
        // design, and an answer that ignored the state would have the cursor
        // offering a resize the press then refuses.
        guard isPinned else { return nil }
        let band = Self.edgeBand
        // A window has a frame, not a bounds; the card's is the content's.
        let size = contentView?.bounds.size ?? frame.size
        let left = point.x < band
        let right = point.x > size.width - band
        let bottom = point.y < band
        let top = point.y > size.height - band
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (true, _, _, true): return .bottomLeft
        case (_, true, true, _): return .topRight
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    /// The frame that follows the hand, keeping the edge that was not grabbed
    /// exactly where it was.
    ///
    /// The minimum is applied to the *size* and the origin is derived from the
    /// anchored edge, so a window dragged past its minimum stops instead of
    /// walking sideways across the screen.
    private func resized(_ start: NSRect, edge: Edge, by delta: NSSize) -> NSRect {
        let minimum = ZoomPreview.minimumSize
        var frame = start
        switch edge {
        case .left, .topLeft, .bottomLeft:
            frame.size.width = max(minimum.width, start.width - delta.width)
            frame.origin.x = start.maxX - frame.size.width
        case .right, .topRight, .bottomRight:
            frame.size.width = max(minimum.width, start.width + delta.width)
        default:
            break
        }
        switch edge {
        case .bottom, .bottomLeft, .bottomRight:
            frame.size.height = max(minimum.height, start.height - delta.height)
            frame.origin.y = start.maxY - frame.size.height
        case .top, .topLeft, .topRight:
            frame.size.height = max(minimum.height, start.height + delta.height)
        default:
            break
        }
        // Growing away from the screen would take the pin with it, and the pin
        // is the way back out of a window that has been made awkward.
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            if frame.maxX > visible.maxX { frame.size.width -= frame.maxX - visible.maxX }
            if frame.maxY > visible.maxY { frame.size.height -= frame.maxY - visible.maxY }
        }
        return frame
    }

    /// Keeps the top-right corner — the pin, and the way out of a window that
    /// has been dragged somewhere strange — on the screen it was dragged on.
    /// Without this a pinned window can be pushed past the edge of the display
    /// and there is nothing left to grab.
    private func clamped(_ origin: NSPoint) -> NSPoint {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return origin }
        let cornerX = min(max(origin.x + frame.width, visible.minX + 60), visible.maxX - 8)
        let cornerY = min(max(origin.y + frame.height, visible.minY + 44), visible.maxY - 8)
        return NSPoint(x: cornerX - frame.width, y: cornerY - frame.height)
    }

    /// Whether the press landed on a control rather than on the paper.
    ///
    /// Asked of the view hierarchy rather than by keeping a rectangle: a
    /// rectangle would have to be recomputed on every resize and would drift
    /// from where the control actually is the first time either moved.
    private func isPressOnControl(_ event: NSEvent) -> Bool {
        isOnControl(event.locationInWindow)
    }

    func isOnControl(_ point: NSPoint) -> Bool {
        guard let content = contentView,
              let hit = content.hitTest(point) else { return false }
        return controls.contains { hit === $0 || hit.isDescendant(of: $0) }
    }

    /// What a drag here would do, said with the cursor.
    ///
    /// The same two questions the press asks, because a cursor that promises
    /// something the press will not do is worse than no cursor at all: an
    /// edge resizes, paper and pictures move the window, a paragraph is
    /// selected. Unpinned, everything is the arrow — a glance is read and
    /// clicked away, and that is the whole of what it does.
    ///
    /// Returns what it decided and the cursor it asked for, so the tick can
    /// say both in the log and check that the set was not ignored.
    @discardableResult
    func applyCursor(for point: NSPoint) -> (note: String, cursor: NSCursor) {
        guard isPinned else {
            NSCursor.arrow.set()
            return ("arrow (a glance)", .arrow)
        }
        if isOnControl(point) {
            NSCursor.arrow.set()
            return ("control", .arrow)
        }
        if let edge = edge(at: point) {
            let shape = cursor(for: edge)
            shape.set()
            return ("edge \(edge.name)", shape)
        }
        let hit = contentView?.hitTest(point)
        if hit?.mouseDownCanMoveWindow ?? false {
            NSCursor.openHand.set()
            return ("open hand", .openHand)
        }
        NSCursor.iBeam.set()
        return ("I-beam", .iBeam)
    }

    /// The modern API has a cursor for each of the eight directions; before
    /// macOS 15 there are only two axes, so a corner borrows one of them.
    ///
    /// Not private so the harness can name what it expects. The cursor that
    /// comes out of here is the one the pointer should be wearing, and that
    /// claim is only worth making if something compares the two.
    func cursor(for edge: Edge) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch edge {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch edge {
        case .left, .right, .topLeft, .bottomRight: return .resizeLeftRight
        default: return .resizeUpDown
        }
    }

    /// Placed under the card that opened it, kept on screen rather than
    /// allowed to hang off the edge of it.
    func place(under anchor: NSPoint, on screen: NSScreen?, content: CGSize) {
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(anchor.x - content.width / 2, visible.minX + 12),
                    visible.maxX - content.width - 12)
        // Below the card, unless there is no room, in which case above it:
        // the zoom covers the card it belongs to, never the line above it.
        var y = anchor.y - content.height - 16
        if y < visible.minY + 12 { y = anchor.y + 22 }
        y = min(y, visible.maxY - content.height - 12)
        setFrame(NSRect(x: x, y: y, width: content.width, height: content.height), display: true)
    }
}

/// The window's content: the card, and the one control laid over it.
///
/// The card stays SwiftUI and the pin is AppKit, which is not an accident.
/// A SwiftUI button would need the window to work out, from the outside,
/// which presses were meant for it — the window closes on a click, and the
/// click arrives before the button does. `PinButton` can answer for itself,
/// and it is the only thing in here that ever needs to.
final class ZoomPane: NSView {
    /// Small enough to sit on a photograph without hiding it, large enough
    /// to be a target rather than a speck.
    static let pinDiameter: CGFloat = 22
    /// Far enough in to sit inside the card's 16pt corner, near enough to the
    /// paper's edge to read as belonging to the window.
    static let pinInset: CGFloat = 14
    /// Short on purpose: the slider is a thing you reach for once, not a
    /// console. It sits to the pin's left, so the pin never moves when it
    /// appears — a button that jumps out from under the hand that just
    /// pressed it would be answering the click with a different button.
    static let sliderWidth: CGFloat = 84
    static let sliderGap: CGFloat = 8

    let host: NSView
    let pin: PinButton
    let opacity: OpacitySlider
    /// The pointer is over the window. The slider appears on it: an unpinned
    /// glance has no business showing a control, and a pinned window should
    /// not wear one while nobody is looking.
    private var hovering = false {
        didSet { updateSliderVisibility() }
    }

    init(host: NSView, pin: PinButton, opacity: OpacitySlider) {
        self.host = host
        self.pin = pin
        self.opacity = opacity
        super.init(frame: .zero)
        // Laid out by hand below. Three children and a corner do not need a
        // constraint solver, and one would fight the freedom of a window the
        // user is dragging by its edge at the time.
        autoresizesSubviews = false
        addSubview(host)
        addSubview(opacity)
        addSubview(pin)
        opacity.target = self
        opacity.action = #selector(opacityChanged)
        opacity.alphaValue = 0
        layoutChildren()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { pointerTimer?.invalidate() }

    /// On `setFrameSize` rather than on `resizeSubviews(withOldSize:)`: with
    /// `autoresizesSubviews` off, AppKit does not walk the subviews at all,
    /// and a container laid out by hand that waits for that walk is a
    /// container whose children sit at zero forever. (It caught the harness
    /// out first: the card drew at its own minimum size in the corner and the
    /// pin sat at −36,−36.)
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    func layoutChildren() {
        host.frame = bounds
        let diameter = Self.pinDiameter
        let pinX = bounds.width - Self.pinInset - diameter
        pin.frame = NSRect(x: pinX, y: bounds.height - Self.pinInset - diameter,
                           width: diameter, height: diameter)
        opacity.frame = NSRect(x: pinX - Self.sliderGap - Self.sliderWidth,
                               y: pin.frame.midY - 8,
                               width: Self.sliderWidth, height: 16)
    }

    /// Pins or releases the window, and takes the slider with it.
    func setPinned(_ pinned: Bool) {
        pin.isPinned = pinned
        updateSliderVisibility()
    }

    /// The cursor follows the pointer, read rather than reported.
    ///
    /// Cursor rects on this container were the first answer and the wrong
    /// one: the SwiftUI card covers the whole window, and AppKit does not
    /// look past the view under the pointer for a cursor. What nothing can
    /// cover is a cursor set explicitly — and what nothing can starve is a
    /// position that is read instead of waited for.

    /// Back to opaque. The window is a glance again, and a glance has no
    /// setting of its own — the same rule that returns it to 640×440.
    func resetOpacity() {
        opacity.doubleValue = 1
        host.alphaValue = 1
    }

    @objc private func opacityChanged() {
        // The card fades; the pin does not. A window at 30% whose own way out
        // has faded with it is a window you cannot get back.
        host.alphaValue = CGFloat(opacity.doubleValue)
    }

    private func updateSliderVisibility() {
        let shown = hovering && pin.isPinned
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            opacity.animator().alphaValue = shown ? 1 : 0
        }
    }

    /// Where the pointer is, in screen coordinates.
    ///
    /// A seam, not an indirection for its own sake: the pointer is the one
    /// thing the offscreen harness cannot move, so it hands this closure a
    /// made-up position and the very same code runs.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// Whether what this code sees goes into the app's log. The harness turns
    /// it off: its pointer is a fiction, and a log full of cursors nobody
    /// moved is worse than no log.
    var logsCursor = true

    private var pointerTimer: Timer?
    private var lastCursorNote = ""

    /// The cursor is read from the pointer, thirty times a second, for as long
    /// as the window is on screen.
    ///
    /// Three earlier answers, each defeated by the same thing — a window that
    /// cannot become key:
    ///
    /// - cursor rects on this container: AppKit only asks the view under the
    ///   pointer, and the SwiftUI card covers all of it;
    /// - `mouseMoved` from a tracking area: whether a mouse-moved event
    ///   reaches a non-key window is not something the documentation promises,
    ///   and the probe that tried to settle it here could not — posting
    ///   synthetic events needs an accessibility grant this binary has not got;
    /// - starting the timer on `mouseEntered`: the window opens *under* a
    ///   pointer that is already inside it, and a boundary that is never
    ///   crossed is an enter that never comes. The timer never started, so the
    ///   cursor never moved. That is the bug the user kept seeing.
    ///
    /// What is left needs nothing from AppKit's event delivery: the window
    /// starts the clock when it appears and stops it when it goes, and each
    /// tick reads where the hand is. One hit test and one cursor set, thirty
    /// times a second, while a small card is on screen.
    private func startPointerTimer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tickCursor()
        }
        // Common modes, or the cursor would freeze for the length of any
        // scroll or resize that ran a tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        tickCursor()
    }

    private func stopPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        lastCursorNote = ""
    }

    /// One tick: read where the hand is, then say what a drag there would do.
    ///
    /// Containment is asked of the frame rather than tracked by enter and
    /// exit, for the reason above: the pointer is usually inside before there
    /// is a window for it to be inside of.
    func tickCursor() {
        guard let zoom = window as? ZoomWindow else { return }
        let location = pointerLocation()
        let inside = zoom.frame.contains(location)
        if inside != hovering { hovering = inside }
        guard inside else {
            // Once, so a resize arrow is not left behind on the desktop — and
            // only once, because a tick that kept setting it would be fighting
            // every other app for the pointer.
            if lastCursorNote != "out" {
                lastCursorNote = "out"
                NSCursor.arrow.set()
                if logsCursor { diagLog("Zoom cursor: pointer out") }
            }
            return
        }
        guard !zoom.isHoldingWindow else { return }
        let (note, want) = zoom.applyCursor(for: zoom.convertPoint(fromScreen: location))
        guard note != lastCursorNote else { return }
        lastCursorNote = note
        guard logsCursor else { return }
        // Whether the set took is the whole question in the field. An app that
        // is not frontmost may set a cursor the window server ignores, and
        // nothing inside this process can tell that from success except by
        // asking what the current cursor actually is.
        diagLog("Zoom cursor: \(note), took \(NSCursor.current == want), pinned \(zoom.isPinned)")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startPointerTimer() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // A window that goes away takes the pointer with it, and the arrow is
        // owed to whatever is underneath.
        if newWindow == nil {
            hovering = false
            stopPointerTimer()
            NSCursor.arrow.set()
        }
    }

    /// The offscreen harness's business, not the app's: pretend the pointer
    /// came in and move the slider, so a picture can be taken of a state that
    /// otherwise needs a hand on a trackpad.
    func rehearse(hovering: Bool, value: CGFloat) {
        self.hovering = hovering
        opacity.doubleValue = Double(value)
        opacityChanged()
        if hovering && pin.isPinned { opacity.alphaValue = 1 }
    }
}

/// The opacity slider.
///
/// A `NSSlider` with one amendment: while it is faded out it is not there as
/// far as the pointer is concerned. A control at zero alpha that still takes
/// the press would be an invisible trap on the paper's top-right corner, and
/// the window closes on a click there.
final class OpacitySlider: NSSlider {
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.5 ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pin.
///
/// The glyph alone, with nothing behind it. It used to sit on a small disc of
/// ink, which was doing two jobs at once — making the control findable, and
/// saying whether it was pressed in. The second job belongs to the glyph: an
/// outline pin is a card that is not held, a filled one is a card that is.
/// That is the same signal the cards on the line give for the same state, and
/// two ways of saying it in one button is one way too many.
///
/// What the disc did leave behind is legibility: the button can land on a
/// photograph, where a 12pt glyph at half strength would disappear. A shadow
/// does that job without drawing a shape nobody asked for.
final class PinButton: NSButton {
    var onPress: (() -> Void)?
    /// Whether the window is being held open, which is also what the glyph
    /// and the ink say.
    var isPinned = false {
        didSet { refresh() }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        wantsLayer = true
        // A shadow off the glyph's own alpha: enough to hold the pin apart
        // from whatever it is drawn on, not a shape of its own.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { onPress?() }

    /// The first click belongs to the pin. A panel that takes no focus does
    /// not get the activation click AppKit would otherwise spend here, but
    /// saying so keeps it true if that ever stops being the case.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The tint is a dynamic colour, and one that was resolved under the old
    /// appearance does not resolve itself again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let symbol = isPinned ? "pin.fill" : "pin"
        let size = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(size)
        contentTintColor = isPinned
            ? NSColor(CDS.clay)
            : NSColor.labelColor.withAlphaComponent(0.55)
        toolTip = isPinned ? L("Let it close") : L("Keep this open")
    }
}

/// What the zoom window draws: the card at size, with the same paper and the
/// same glass, so a snippet read here is the snippet that is on the line.
///
/// Not `private` only because the offscreen harness in `EditorPreview` builds
/// one to photograph; nothing else outside this file has a reason to.
struct ZoomCard: View {
    let preview: ZoomPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preview.payload.isImage, let url = preview.payload.imageURL,
               let image = NSImage(contentsOf: url), image.size.width > 0 {
                // Aspect-fit inside the window, and centred: a screenshot
                // stretched to fill a fixed box is a lie about what it shows.
                // A very tall or very wide one is a different lie the other
                // way — filling to the width and scrolling for the height —
                // so the aspect fit is the one that never distorts, and the
                // window is the size the picture needs up to a limit.
                //
                // A picture holding a code gets a strip under it saying what
                // the code says. Under rather than over: the picture is still
                // the thing being looked at, and the code is what it turned
                // out to hold. A picture holding nothing keeps the whole
                // window, exactly as it had before any of this existed.
                VStack(spacing: 0) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let text = preview.qrcodes?.first {
                        CodeReading(text: text, isLink: QRCodes.link(in: text) != nil)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if preview.payload.files.count > 1 {
                // Several files are not a document, so there is nothing to
                // render. They are listed: the point of looking is to see
                // what is in the pile before dragging it somewhere, and one
                // file's preview would be a detail of a selection rather than
                // the selection.
                SeveralFiles(files: preview.payload.files)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = preview.payload.fileURL {
                // The system's own renderer, not a note about why there is
                // not one. Writing a renderer per format is a project the
                // size of Preview itself, and this is the view form of the
                // thing macOS has used for twenty years — it knows formats
                // this app has never heard of and will keep knowing them
                // after this stops compiling.
                //
                // It needs its framework linked by hand, and the properties
                // its documentation names are not the ones it has: a preview
                // item and a delegate, not a data source. That is written
                // down here because the next person to read the
                // documentation will get it wrong the same way.
                SystemPreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .note(let note) = preview.payload {
                // A note reads as its plain text, the same words a paste
                // carries — ticks spelled out. Editing happens elsewhere
                // (the corner mark, the long press, the menu); the reader
                // only shows, which is what a space asks of it.
                ReadingText(text: note.plainText, isCode: false)
            } else if case .text(let string, let isCode) = preview.payload {
                ReadingText(text: string, isCode: isCode)
            }
        }
        // The window decides how big this is. It opens at `size`, and once it
        // is pinned the hand does — and everything inside already copes: a
        // picture is aspect-fit inside the box, text rewraps in its scroll
        // view, a list of files shows more of itself. The floor is the only
        // thing this view insists on, so a window cannot be dragged down to
        // a sliver with a corner of a photograph in it.
        .frame(minWidth: ZoomPreview.minimumSize.width,
               minHeight: ZoomPreview.minimumSize.height)
        // Everything below is wrapped in one compositing group so the corner
        // radius is decided once, at the outside, and nothing drawn inside can
        // put a square edge back. Shadow is the other half: a shadow drawn
        // outside a clip is the shape of what casts it, and if the clip is
        // inside a group the shadow is drawn from the group's rectangle — a
        // soft square exactly the size of the window, whose four corners are
        // what has been showing round the card.
        // No shadow here. A shadow is drawn from the shape casting it and
        // SwiftUI has been drawing this one from a rectangle the size of the
        // window, which is the square that kept appearing around the card. The
        // window's own layer clips to the radius; a shadow would have to be
        // drawn outside the window to survive, which a panel this size has
        // no room for. The paper is drawn flat and the window's edge is the
        // only edge.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PayloadCard.paper)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
    }
}

/// The strip under a picture that held a code: what it says, and where to go
/// to do something with it.
///
/// No button, and not for want of trying. The zoom window does not take the
/// mouse at all — any click dismisses it — so a button drawn here would be a
/// control that cannot be pressed, which is worse than no control. The card's
/// right-click menu is where a code is copied or followed; this is where it is
/// read, and the hint says so rather than leaving the user to guess.
private struct CodeReading: View {
    let text: String
    let isLink: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    // Not selectable, though it is reading matter. The zoom
                    // window takes no mouse events at all — every click
                    // dismisses it — so a selection here would be a
                    // decoration: the pointer never reaches the text. Copying
                    // is the right-click menu's job, and the hint below says
                    // where it is.
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(isLink ? L("Right-click the card to open the link")
                            : L("Right-click the card to copy the contents"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A wash rather than a panel: it is part of the picture's window, not
        // a thing laid on top of it. Resolved from `primary` so it darkens in
        // the light and lightens in the dark, which is the same relationship
        // the paper and the glass already have.
        .background(Color.primary.opacity(0.055))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
    }
}

/// The reading half of a text or note zoom: the whole thing, scrolling
/// rather than truncating — the reason to open this is that the card cut the
/// text off, and a zoom that cut it off too would have solved nothing.
private struct ReadingText: View {
    let text: String
    let isCode: Bool

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(isCode ? .system(size: 13, design: .monospaced)
                             : .system(size: 14))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The pin owns the top-right corner, and text gives it that
                // line rather than sharing it. A right gutter would do the
                // same and cost every line of every window; only the first
                // line is ever under the button.
                .padding(.horizontal, 16)
                .padding(.top, ZoomPane.pinDiameter + ZoomPane.pinInset + 2)
                .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
    }
}

/// Owns the one zoom window there is, and the keys that open and close it.
@MainActor
final class ZoomController {
    static let shared = ZoomController()

    private var window: ZoomWindow?
    /// The view the card is drawn in, kept so a second card can replace the
    /// first inside the same window rather than building a new one.
    private var host: NSHostingView<ZoomCard>?
    /// The pin, kept for the same reason: its state outlives any one card.
    private var pin: PinButton?
    /// The container, kept for the one thing only it can do: put the controls
    /// back the way an unpinned window wears them.
    private var pane: ZoomPane?
    /// Whether the window is held open. A glance closes on a click anywhere;
    /// a pinned window stays until it is told otherwise, and that is the
    /// whole of the difference.
    private var pinned = false
    /// The card the zoom belongs to, so a second press on it closes rather
    /// than reopens, and a press on another card replaces it.
    private var showing: UUID?
    /// Every card on the line, so a press on a card can be answered without
    /// asking where the pointer is.
    private var registry: [UUID: Pegged] = [:]
    /// Where the zoom was last put, so a card whose contents change under it
    /// can be shown again in the place the user is already reading.
    private var lastAnchor: NSPoint?
    /// Keys is monitored rather than handled by the panel: the panel cannot
    /// become key, so it never receives a key event at all.
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var globalClick: Any?
    /// Whoever had the front when the window was pinned, so it can have it
    /// back. Not a nicety: the front was borrowed from them for as long as the
    /// user was working in this window.
    private var previousApp: NSRunningApplication?

    private init() {}

    /// Whether the zoom is showing this card, so the card can say so.
    func isShowing(_ id: UUID) -> Bool { showing == id }

    /// Whether the zoom is showing anything at all.
    ///
    /// Asked by the space key, which arms itself from "is the pointer on a
    /// card" — a question that stopped being the same one the moment this
    /// window took the mouse. With the pointer over the window it is over no
    /// card, and a key that disarmed there would leave a reader holding a
    /// page it cannot put down.
    var isShowingAny: Bool { showing != nil }



    /// Opens or closes a card's zoom from a press on the card itself.
    ///
    /// The card knows where it is and what it holds; this is told rather than
    /// asked, because the only thing it would ask for — which card is under
    /// the pointer — is a question about where the pointer is, and the press
    /// that arrived here has already answered it.
    func toggleZoom(id: UUID, anchor: NSPoint) {
        guard let item = lookup(id) else { return }
        if showing == id {
            dismiss()
            return
        }
        // Some things are somewhere you can go rather than something you read
        // at a size: a folder is a place to put files, a link is somewhere to
        // be taken. Those are acted on. Everything else — a document, an
        // archive, a picture, a line of text — is opened in a window, which
        // is where the system knows how to show it.
        //
        // An archive is a window and not an unpacking. Unpacking is a thing a
        // person asks for, on purpose, having looked at what is in it; a
        // click on a card is a request to look, and answering it by writing
        // files into a folder beside the thing is how a pile of rubbish
        // appears without anyone having decided to make one.
        switch item.payload {
        case .file(let urls):
            // One folder is somewhere to go. One file — and any number of
            // them, since several are a list to look at rather than a thing
            // to open — is something to look into, which is what the window
            // is for and the only place that can do it.
            if urls.count == 1 {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    NSWorkspace.shared.open(urls[0])
                    return
                }
            }
            present(item, at: anchor, on: anchorScreen(anchor))
        case .text(let string, _):
            // A link goes where it points. Everything else is text, and text
            // is read in the window like anything else.
            if let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
               PayloadCard.isLink(item.payload) {
                NSWorkspace.shared.open(url)
            } else {
                present(item, at: anchor, on: anchorScreen(anchor))
            }
        case .image:
            present(item, at: anchor, on: anchorScreen(anchor))
        case .note:
            // Never reached, and it has to be said here anyway. A note is the
            // one card whose content lives only in this app, so the press that
            // opens it goes to the editor rather than to a reader — the card
            // routes both the double click and the corner mark there, and the
            // zoom is never handed one. If that ever stops being true, the
            // right answer is an editor and not a window of uneditable text.
            break
        }
    }


    /// Hands the line over to the zoom, so a press on a magnifier can be
    /// answered from the card itself.
    func register(contentsOf items: [Pegged]) {
        registry = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }
    private func lookup(_ id: UUID) -> Pegged? { registry[id] }

    /// The card the zoom is showing has changed since it was opened — a code
    /// in it was read, and the window was already drawn.
    ///
    /// Shown again, in the same place, and only when it is the card already on
    /// screen: a code read for some other picture on the line has nothing to
    /// do with what the user is reading. This is the half-second between a
    /// card hanging and its code being known, where a space pressed in that
    /// half second would otherwise open a window that never learns.
    func refresh(_ item: Pegged) {
        guard showing == item.id, let anchor = lastAnchor else { return }
        // A pinned window keeps the size and the place it was given. What is
        // inside it changing is not a reason to resize a window the user has
        // just dragged to what they wanted.
        if pinned, let host {
            host.rootView = ZoomCard(preview: ZoomPreview(payload: item.payload,
                                                          origin: item.origin,
                                                          anchor: anchor,
                                                          qrcodes: item.qrcodes))
            return
        }
        present(item, at: anchor, on: anchorScreen(anchor))
    }

    /// The screen an anchor point is on, which is where the window goes.
    private func anchorScreen(_ anchor: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
    }

    func toggle(_ item: Pegged, at anchor: NSPoint, on screen: NSScreen?) {
        if showing == item.id {
            dismiss()
            return
        }
        present(item, at: anchor, on: screen)
    }

    private func present(_ item: Pegged, at anchor: NSPoint, on screen: NSScreen?) {
        let preview = ZoomPreview(payload: item.payload, origin: item.origin,
                                  anchor: anchor, qrcodes: item.qrcodes)
        // A second zoom reuses the window rather than making another, so
        // there is never more than one thing floating over the line. Only the
        // card inside it is replaced.
        let panel = window ?? makeWindow(with: preview)
        host?.rootView = ZoomCard(preview: preview)
        if panel.frame.height < 1 { panel.setContentSize(ZoomPreview.size) }
        // The press that dismisses arrives at the window rather than at a
        // monitor: the window takes the mouse now, so a click inside it never
        // reaches `globalClick` below — that one only ever hears the events
        // going to *other* applications.
        panel.onPress = { [weak self] in self?.dismiss() }
        panel.place(under: anchor, on: screen ?? panel.screen, content: panel.frame.size)
        panel.orderFrontRegardless()
        showing = item.id
        lastAnchor = anchor
        watchForDismiss()
    }

    /// The window, the card inside it and the controls on top of it, made once.
    private func makeWindow(with preview: ZoomPreview) -> ZoomWindow {
        let card = NSHostingView(rootView: ZoomCard(preview: preview))
        card.wantsLayer = true
        card.layer?.backgroundColor = .clear
        let pin = PinButton()
        pin.onPress = { [weak self] in self?.togglePin() }
        let opacity = OpacitySlider(value: 1, minValue: 0.3, maxValue: 1,
                                    target: nil, action: nil)
        opacity.controlSize = .small
        opacity.isContinuous = true
        let pane = ZoomPane(host: card, pin: pin, opacity: opacity)
        let made = ZoomWindow(content: pane)
        made.controls = [pin, opacity]
        made.onPress = { [weak self] in self?.dismiss() }
        host = card
        self.pin = pin
        self.pane = pane
        window = made
        return made
    }

    /// Holds the window open, or lets it go back to being a glance.
    private func togglePin() {
        guard let window, showing != nil else { return }
        pinned.toggle()
        pane?.setPinned(pinned)
        window.setPinned(pinned)
        if pinned {
            takeFront(window)
            // Nothing outside closes it now. The press that used to mean
            // "away" means nothing, which is what holding a window open is.
            stopWatchingForOutsideClicks()
        } else {
            giveFrontBack()
            watchForDismiss()
        }
    }

    /// Borrows the front for as long as the window is held open.
    ///
    /// Measured, not reasoned about: two identical panels were put under the
    /// pointer with an open hand set, one by a frontmost app and one by an app
    /// that was not frontmost, and photographed. The frontmost one drew a
    /// hand; the other drew an arrow. The pointer is drawn by the window
    /// server for the frontmost application only, so a pinned window that
    /// wants to say "this edge resizes" has to be the front app first.
    ///
    /// The glance does not do this and must not: it is opened, read and
    /// clicked away without the app the user was typing in ever noticing.
    private func takeFront(_ window: ZoomWindow) {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        diagLog("Zoom pin: took the front from \(previousApp?.localizedName ?? "nobody")")
    }

    /// Gives it back, so the user is left where they were.
    private func giveFrontBack() {
        guard let previousApp else { return }
        self.previousApp = nil
        if #available(macOS 14.0, *) {
            previousApp.activate(from: NSRunningApplication.current, options: [])
        } else {
            previousApp.activate(options: [])
        }
        diagLog("Zoom pin: gave the front back to \(previousApp.localizedName ?? "nobody")")
    }

    /// Puts the window away — unless it is being held open.
    ///
    /// A pinned window goes away for nothing: not a click on its own paper,
    /// not a click in another app, not the key that opened it, not escape.
    /// The way out is the pin, which releases it back to being a glance, and
    /// from there one click does what one click always did. Every route that
    /// ends a preview funnels through here — the press inside the window, the
    /// click outside it, escape, the card's own key — so the rule is written
    /// once, here, instead of at each of them. It was written at none of them
    /// once, and pinning a window then clicking its own paper closed it.
    func dismiss() {
        guard !pinned else { return }
        window?.orderOut(nil)
        // Back to the size a glance opens at, and out of the pinned state:
        // the next space is a new look rather than a continuation of this one.
        if (window?.frame.height ?? 0) != ZoomPreview.size.height {
            window?.setPinned(false)
            window?.setContentSize(ZoomPreview.size)
        }
        // Opaque again, for the same reason: a glance has no settings of its
        // own to remember.
        pane?.resetOpacity()
        showing = nil
        lastAnchor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        stopWatchingForOutsideClicks()
    }

    /// Any click anywhere closes it, including a click on the card that
    /// opened it — the zoom is a reading pane, not a place to click.
    private func watchForDismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // escape
                MainActor.assumeIsolated { self?.dismiss() }
            }
            return event
        }
        // A pinned window is not watching for this at all: it is held open,
        // and `dismiss` would refuse anyway. Not installing the monitor also
        // saves the app a callback on every click in every other app.
        guard !pinned, globalClick == nil else { return }
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// Stops listening for the click that would put a glance away.
    ///
    /// Escape is left alone on purpose — it is in `keyMonitor` above, and it
    /// is the one way out that a pinned window keeps.
    private func stopWatchingForOutsideClicks() {
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        globalClick = nil
    }
}

/// The system's own renderer for a document, embedded.
///
/// `QLPreviewView` rather than `QLPreviewPanel`: the panel is the one that
/// looks like Finder's, and it wants the key window, which a strip over the
/// top of the screen cannot take. The view form has no such requirement.
///
/// The framework is linked by hand in Package.swift because SwiftPM does not
/// link it on its own, and the properties its documentation names are not the
/// ones it has — a preview item, not a data source. That is worth writing
/// down: the next person to read the documentation will get it wrong too.
struct SystemPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Compared by URL, so a second document is not reloaded on every
        // update and the scroll position is not thrown away under the reader.
        if (view.previewItem as? NSURL) != url as NSURL {
            view.previewItem = url as NSURL
        }
    }
}

/// The contents of a card holding several files: each one named, with its
/// icon, and the folder it is in when they do not share one.
///
/// A selection is worth reading before it is worth dragging. A path — which
/// is what a file preview shows for one file — says nothing about a pile of
/// them, and reading twenty paths is not something a person does.
private struct SeveralFiles: View {
    let files: [URL]

    /// Where they are, when they are not all in the same place.
    private var foldersDiffer: Bool {
        Set(files.map { $0.deletingLastPathComponent().path }).count > 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: icon(for: url))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if foldersDiffer {
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 14)
                    if url != files.last {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(PayloadCard.paper)
    }

    private func icon(for url: URL) -> NSImage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return NSWorkspace.shared.icon(for: .data)
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
