import AppKit

/// The two window levels the capture uses.
///
/// `.popUpMenu + 1` rather than `.screenSaver`. The screen-saver tier was the
/// first choice, on the reasoning that the highest tier is the safest at covering
/// things — and it does cover them. But long mode needs a window *above* the
/// overlay that still takes clicks while this app is not frontmost, and the
/// screen-saver tier is where the window server starts treating windows as
/// something other than ordinary windows. The reference implementation stays out
/// of that tier on purpose (its comment: "cover captured menus without using the
/// screen-saver/security window tier"), and everything the capture has to cover —
/// the line at `.floating`, the Dock, the menu bar, an open menu at `.popUpMenu` —
/// lives below it. Nothing here needs to be higher than a menu.
enum CaptureLevels {
    static let overlay = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    static let button = NSWindow.Level(rawValue: overlay.rawValue + 1)
}

/// The window the whole capture happens in: one per screen, sized to it,
/// above everything, and the only thing on screen that can take a key.
///
/// A plain `NSWindow` rather than an `NSPanel`. The line is a panel because it
/// must never take focus; this is the opposite — it has to, or Esc, Space and
/// Return never arrive. `canBecomeKey` is overridden for the same reason:
/// borderless windows refuse by default.
final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, surface: CaptureSurface) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = CaptureLevels.overlay
        // Every Space, and a full screen app too: the thing being photographed
        // is very often a full screen window, and a capture that could not
        // reach it would be a capture that works everywhere except where it is
        // wanted.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // The pointer is doing the pointing, and every movement over this
        // window is the user choosing where to shoot. Nothing here scrolls.
        acceptsMouseMovedEvents = true
        contentView = surface
    }
}

/// What this capture is about to take.
///
/// One value rather than three callbacks that each carry half an answer: the
/// bar's `编辑`, the Return key and a double-click all ask the same question —
/// "what is chosen" — and two answers to it would drift. The window case keeps
/// its identity because a window is photographed from its own surface, which is
/// the whole reason a covered window still comes out whole; a rectangle is
/// cropped out of the frozen backdrop.
enum CaptureTarget {
    case window(PickableWindow)
    case region(CGRect)
}

/// The symbols the bar's chips draw, named once.
///
/// Named here rather than spelled at each call site because a symbol name is a
/// fact about the operating system, not about this app: one that has been
/// renamed or withdrawn draws as a blank box, and nothing else in the build
/// would notice. The list is short enough to be checked against
/// `NSImage(systemSymbolName:)` on every self-test run, which is the only way to
/// find out before somebody opens the bar and sees five empty squares.
enum CaptureSymbol {
    static let ratio = "aspectratio"
    /// A scroll: the one picture that says "longer than the screen" without a
    /// word. The arrow it replaced said "down", which is half the story and
    /// reads as a download at 14 points.
    static let long = "scroll"
    static let read = "text.viewfinder"
    /// A bubble with a character in it, rather than `translate`.
    ///
    /// `translate` is two overlapping bubbles, and the rear one ends exactly in
    /// the bottom right corner — which is where this bar puts the key. The `T`
    /// landed on that bubble's outline and read as a smudge, reported as soon as
    /// the keys moved into the corners. `character.bubble` is one bubble whose
    /// tail is bottom *left*, so the corner the letter needs is empty, and it
    /// still says "words, spoken in another language".
    static let translate = "character.bubble"
    /// A pencil over a scribble: writing on the picture, which is what the
    /// editor is for. Three earlier answers were all pictures of a pencil
    /// (`pencil`, `highlighter`); this one is the only one that shows a pencil
    /// *at work*, and at 14 points that difference is what tells it apart from
    /// the rectangle beside it.
    static let edit = "pencil.and.scribble"
    /// A dashed frame — the frame that comes back, still empty.
    ///
    /// This button does not take a second picture and does not reopen the last
    /// one: it puts the frame back where it was and waits for a person to press
    /// Return. That is precisely what a dashed frame means, and it is why this
    /// beat the whole family of return arrows (`arrow.uturn.backward`,
    /// `arrow.uturn.backward.square`): an arrow says "back", never "this frame
    /// is on screen but nothing has been taken yet".
    static let again = "rectangle.dashed"
    /// In the order they are drawn, which is also the order they are read.
    static let all = [ratio, long, read, translate, again, edit]
}

/// What the capture draws and what it hears.
///
/// One view for the whole gesture rather than a view per control: the dimmed
/// backdrop, the highlight, the selection, the size badge and the hint are all
/// things drawn at the same moment from the same state, and splitting them
/// across subviews would mean five places to keep in step for a window that
/// lives a second.
///
/// Coordinates: everything stored here is in AppKit's screen space (origin at
/// the bottom left of the main display, y running up), because that is what
/// `NSScreen`, `CGWindowList`'s converted frames and the final crop all speak.
/// The view is not flipped, so its own space is the screen's shifted by the
/// window's origin — which makes the conversion one subtraction.
@MainActor
final class CaptureSurface: NSView {
    /// The picture taken before the overlay appeared, and the screen it is of.
    ///
    /// A still rather than a live stream: the picture being chosen is the
    /// picture as it was when the gesture started, the backdrop never has to
    /// be composited twice a frame, and drawing it is what makes the dimming
    /// exact instead of approximate.
    private let backdrop: CGImage
    private let screen: NSScreen
    private let backdropImage: NSImage
    /// The windows the pointer may land on, front to back.
    private let windows: [PickableWindow]
    /// Whether there is a capture to do again.
    ///
    /// Read once, when the surface is made. The bar is laid out many times a
    /// second — every hover, every drag step — and a defaults read in the middle
    /// of that is a decode per frame for an answer that cannot change while a
    /// capture is up.
    private let againShown: Bool

    /// The window under the pointer — lit up as the thing a click would take.
    ///
    /// A hover is a question, not an answer (2026-11-03): it says "this is what
    /// a press would choose", and the press is what chooses. The chosen one is
    /// `chosenWindow` below, and the two are drawn differently — a thin white
    /// outline for the question, the same clay frame a dragged rectangle wears
    /// for the answer.
    private var hovered: PickableWindow?
    /// The window that has been chosen, if the choice was a window rather than
    /// a drag. Its frame is in `selection` — one rectangle, one set of geometry —
    /// and this is the identity beside it: a window is photographed from its own
    /// surface, a rectangle is cropped out of the screen, and the difference
    /// cannot be recovered from four numbers.
    private var chosenWindow: PickableWindow?
    /// What has been dragged out, in screen coordinates. Nil until the drag
    /// passes the threshold that tells it apart from a click, and it stays
    /// after the release: a frame that is drawn is a frame that can still be
    /// adjusted.
    private var selection: CGRect? {
        didSet {
            // The frame on screen is no longer the one `重截` put back: it is
            // being drawn, moved, resized, replaced by a window or by the whole
            // screen. The light belongs to the replay, not to any rectangle, so
            // it goes out here — one place, because every road that changes the
            // frame comes through this property.
            //
            // Compared rather than assumed: `restore` sets the same rectangle it
            // is about to light, and a report after a rescale or a reshape of an
            // unchanged frame must not put the light out.
            if selection != oldValue { againShowing = false }
        }
    }
    /// What the press in progress has hold of. One value rather than three
    /// booleans, because the three are exclusive — a press that is resizing an
    /// edge is not also drawing a new rectangle, and a flag left over from the
    /// last press would be a state that cannot happen and can still be read.
    private var press: Press = .idle
    /// Whether this press has moved far enough to be a drag rather than a
    /// click. Three points: the same slack the line uses to tell a press from a
    /// drag, so the two gestures feel alike across the app.
    private var dragged = false
    /// Whether the mouse went down on the bar. The bar answers `mouseDown` by
    /// opening its panel, and the release that follows belongs to the bar as
    /// well: without saying so, `mouseUp` took it for a click on the desktop
    /// and cancelled the whole capture — a button that dismissed the thing it
    /// was supposed to configure.
    private var barPress = false
    private static let dragSlop: CGFloat = 3

    /// True while a press is in progress, whatever it is doing. The pointer
    /// watch stands down for all three kinds: a press that is moving the frame
    /// is not also choosing a window.
    private var pressing: Bool {
        if case .idle = press { return false }
        return true
    }

    /// The shape a drag is held to, `.free` until `R` is pressed.
    ///
    /// The editor's nine, from the editor's own enum: a 9:16 cover or a 2.35:1
    /// header is the same shape whether it is being cropped out of a picture or
    /// captured off the screen, and a second list would drift from the first.
    /// Pressing `R` after a rectangle is drawn reshapes it rather than waiting
    /// for the next drag — the moment someone wants a fixed shape is the moment
    /// they see the rectangle is not one.
    var aspect: CropAspect = .free {
        didSet {
            guard aspect != oldValue else { return }
            reshapeSelection()
            needsDisplay = true
        }
    }

    /// What the surface asks for. Wired once, by the controller.
    var onPick: (PickableWindow) -> Void = { _ in }
    var onFinish: (CGRect) -> Void = { _ in }
    /// The same target as Return, taken one step further: the picture lands the
    /// way it always lands, and then opens in the editor instead of being left
    /// alone. One press for a capture and an edit, which is what "编辑" on this
    /// bar is asking for — nobody wants the shot now and the editor after.
    var onEdit: (CaptureTarget) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// The same area as last time, asked for again. Nothing about the rectangle
    /// on screen is involved: the controller holds what was captured last, and
    /// this press is the whole of the request.
    var onAgain: () -> Void = {}
    /// The stitched picture, when a long capture ends.
    var onFinishLong: (CGImage) -> Void = { _ in }
    /// The area whose words should be read. The controller cuts it out of the
    /// backdrop and runs Vision, because that is the half that owns pictures;
    /// the answer comes back through `showReading(_:)`.
    var onReadArea: (CGRect) -> Void = { _ in }
    /// The words, on their way to the line as text rather than as a picture.
    var onFinishText: (String) -> Void = { _ in }
    /// Long mode has begun: the front, and with it the keyboard, is about to be
    /// given to the app being scrolled. The controller takes that on because it
    /// owns the app-level half — activating, and listening for the two keys
    /// that have to work while this app is not front.
    var onEnterLongMode: () -> Void = {}

    /// Whether this is one picture or a region that keeps growing downwards.
    private enum Mode { case shot, long }
    private var mode: Mode = .shot
    /// Long was asked for before there was a region to grow. The next drag
    /// becomes that region rather than being thrown away for having no shape.
    private var longArmed = false
    private let stitcher = LongStitcher()
    /// The sampling clock, running while long mode is up.
    private var sampling: Timer?
    /// One sample in flight at a time: a grab that took longer than the tick
    /// would otherwise have a second one started on top of it, and two frames
    /// out of order is a stitch that tears.
    private var busy = false
    /// What the last sample had to say — too fast, or the wrong way.
    private var longNote: String?
    /// Whether the pointer is over the Done pill.
    ///
    /// Reported by the window laid over the bar rather than worked out here:
    /// this view is inside a window that ignores the mouse, so it is the last
    /// thing in the capture to learn where the pointer is.
    private var doneHover = false
    /// Whether the pointer is over the ✕.
    private var closeHover = false

    /// Whether the frame on screen is one `重截` put back.
    ///
    /// A state, not a press: while that frame is up, `重截` is lit, because what
    /// the chip is saying is "this rectangle came from the last capture" and
    /// that keeps being true until the rectangle stops being that one — a new
    /// drag, another window, the whole screen, a resize. Cleared by the frame
    /// changing (see `selection`), set by `restore`.
    ///
    /// The first version of this was a 0.3 s glow, which was a mistake of
    /// category: the light was timed like a button press when the thing it
    /// describes is a frame that stays on screen. The user's correction was
    /// 「出现的对话框就应该是出现的，它在出现的过程中，就应该一直是亮的」.
    private var againShowing = false {
        didSet { if againShowing != oldValue { needsDisplay = true } }
    }

    /// What the region is doing once `识别` has been pressed.
    ///
    /// A third answer to "what is this area for", beside a picture and a region
    /// that keeps growing — and the only one that produces no picture at all.
    /// The words are the capture; the file is not.
    private enum Reading: Equatable {
        /// The pixels are cut and Vision is looking at them.
        case going
        /// What it read. Non-empty: an empty string is `.nothing` instead, so
        /// "read it and found nothing" and "have not read it yet" can never be
        /// the same state.
        case found(String)
        /// Looked at, holds no words.
        case nothing
    }
    private var reading: Reading?
    /// `识别` was chosen before there was a region. The next drag is the region
    /// to read, the way `longArmed` treats the next drag as the one to grow.
    private var readArmed = false
    /// `译` was chosen before there was a region.
    private var translateArmed = false
    /// Which door the region came in through.
    ///
    /// The pixels and the Vision request are the same either way; what differs
    /// is what happens to the words afterwards — one hangs them on the line,
    /// the other puts them back on the screen and keeps nothing.
    private enum ReadingPurpose { case hang, translate }
    private var readingPurpose: ReadingPurpose = .hang
    /// Harness only: the words a reading would show. There is no screen for a
    /// harness to read, and the bar is exactly what needs looking at.
    var previewReading: String?
    /// Harness only: the translation of those words, as if one had come back.
    var previewTranslation: String?

    /// Harness only: the sheet of words, having come in through `识别` — the
    /// pill says `确认` because that is what pressing it does.
    func showReadingForTesting(_ text: String?) {
        previewReading = text
        readingPurpose = .hang
        needsDisplay = true
    }

    /// Harness only: the same sheet, having come in through `译` — the words in
    /// the other language and a pill that says `复制`.
    func showTranslationForTesting(_ text: String, from words: String?) {
        previewReading = words
        readingPurpose = .translate
        previewTranslation = text
        needsDisplay = true
    }

    /// The words, in the other language — never both in this state.
    ///
    /// A translation is a capture of its own: what it is for is reading the
    /// other language, so that is what the sheet shows once it arrives. The
    /// reading it came from is not kept beside it, because nothing hangs on the
    /// line afterwards — this module ends on the screen.
    private var translation: String?
    /// A translation is on its way.
    ///
    /// Half a second once the engine is warm; minutes the first time a language
    /// pair has to be downloaded, with a system sheet asking for it. A state of
    /// its own is the difference between "still working" and "nothing happened".
    private var translating = false
    /// Why there is no translation, when there is none.
    ///
    /// Three answers because they lead to three different next steps: the words
    /// are in a language this could not name (draw the area over more of it),
    /// this Mac cannot work with that pair at all (change 译成), or the engine
    /// was asked and did not answer (try again). One sentence for all three
    /// would leave the person with the same useless word for three different
    /// problems.
    enum Refusal {
        /// No telling what language those words are in.
        case unsure
        /// The engine has no such pair.
        case unsupported
        /// Asked, and the answer never came.
        case failed
    }
    private var refusal: Refusal?
    /// The words are already in the language asked for.
    ///
    /// Its own state rather than a failure, because "cannot" and "already is"
    /// are different answers and only one of them is bad news. The system's
    /// engine does not return the same words for this case — it fails, with
    /// `nothingToTranslate` — which is exactly why it has to be caught rather
    /// than compared for.
    private var translateNoop = false
    /// The controller asks the engine and comes back through
    /// `showTranslation(_:)`; nil means it could not.
    var onTranslate: (String) -> Void = { _ in }
    /// The translation, on its way out. Nothing hangs on the line: what was
    /// asked for was to read this area in another language, and the reading is
    /// over when the screen goes away.
    var onFinishTranslation: (String) -> Void = { _ in }

    /// What the region is showing, in the harness or for real.
    private var readingState: Reading? { reading ?? previewReading.map { .found($0) } }

    /// The translated words, wherever they came from.
    private var translationText: String? { translation ?? previewTranslation }

    /// What the sheet of words says.
    ///
    /// A translation, once there is one, is the whole answer — it replaces the
    /// words in place instead of joining them, because the area on the screen is
    /// the size of the words that were there and twice as many words would be
    /// twice as many as fit.
    private var shownText: String? {
        if let translationText { return translationText }
        if case .found(let text)? = readingState { return text }
        return nil
    }

    /// The rectangle this capture is about, in screen coordinates.
    ///
    /// Handed out for one purpose: remembering what to do again. A `译` or a
    /// `识别` is chosen before the drag and lands without the controller ever
    /// being told the figure, so the figure has to be asked for rather than
    /// passed along — and asking here means one answer rather than a second
    /// copy of the selection kept somewhere else.
    var region: CGRect? { selection }

    /// Whether the frame on screen has corners to pull and a body to move.
    ///
    /// A window is not a rectangle: its frame *is* the window's, and neither
    /// the eight handles nor the move gesture may touch it. The same fact is
    /// drawn (`draw`) and felt (`mouseDown`), so it is named once here instead
    /// of spelled out at both ends — two spellings of one condition is how the
    /// dots come back while the hand cannot use them, or the other way round.
    var frameIsResizable: Bool { selection != nil && chosenWindow == nil }

    /// The sentence the bar is currently saying, for the harness.
    ///
    /// Two states can differ in nothing but this string — a frame dragged to
    /// the edges and a frame filled by Space are the same numbers — so the
    /// claim "Space says what it did" can only be checked as a sentence.
    var lineForTesting: String { bar().lineText }

    /// The buttons are gone and the middle of the bar is a readout, with the way
    /// out on the right: true while a long capture runs, and while a reading is
    /// waiting to be answered. Deliberately not `growing`, which is about the
    /// picture made of frames and drives the transparent window as well.
    private var collapsed: Bool { mode == .long || readingState != nil || previewLong != nil }

    /// Set only by the layout harness, which has no pointer to hover and no
    /// hand to drag. Ordinary runs leave both nil and the two live answers —
    /// the window under the pointer and the rectangle being drawn — are used
    /// instead.
    var previewHighlight: CGRect?
    var previewSelection: CGRect?
    /// Harness only: the height the bar shows while a long capture runs. A
    /// harness that scrolled a page to test a long capture would be a harness
    /// testing the page.
    var previewLong: Int?
    /// Harness only: the note a wrong-way scroll would put on the line. The
    /// point of photographing it is to show the capsule does not change when it
    /// appears, which cannot be seen at all if it only ever appears for real.
    var previewNote: String?

    /// The pointer is watched rather than reported.
    ///
    /// `mouseMoved` is not delivered for the position the pointer already had
    /// when this window appeared: the window is put under a stationary pointer,
    /// no boundary is crossed, and so nothing arrives until the hand moves. The
    /// capture would open with no window lit, which reads as "it did not find
    /// anything" right at the moment it is supposed to have found everything.
    /// The same lesson `ZoomPreview` learned; the same answer.
    private var pointerWatch: Timer?
    private var lastPointer: NSPoint?

    init(backdrop: CGImage, screen: NSScreen, windows: [PickableWindow]) {
        self.backdrop = backdrop
        self.screen = screen
        self.windows = windows
        self.againShown = LastCapture.stored != nil
        // Scaled to the screen's own points so the drawing is 1:1 rather than
        // resampled per frame: the image is at backing resolution, the view is
        // at point resolution, and giving the image the size it is drawn at is
        // what stops AppKit guessing.
        self.backdropImage = NSImage(cgImage: backdrop, size: screen.frame.size)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        // The capture is the one thing that must see the pointer at rest.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pointerWatch?.invalidate()
    }

    override var acceptsFirstResponder: Bool { true }

    /// A capture is a one-shot tool, and the click that presses its one button
    /// is the click. Requiring a second one — the first only activating the
    /// window — reads as a button that did not work, which is how a copy that
    /// did land was reported.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: The pointer

    /// Starts the watch. Called when the window is on screen, not in `init`:
    /// a timer that starts before there is a window spends its first ticks
    /// answering questions about a capture nobody can see yet.
    func beginTracking() {
        lastPointer = NSEvent.mouseLocation
        refreshHover()
        pointerWatch?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` rather than `.default`: the watch has to keep running while
        // a tracking loop or a menu is up, which is exactly when the pointer is
        // moving and the answer matters.
        RunLoop.main.add(timer, forMode: .common)
        pointerWatch = timer
    }

    func endTracking() {
        pointerWatch?.invalidate()
        pointerWatch = nil
        // Whatever the capture was doing, it is over: the controller calls this
        // both when the overlay closes and when long mode starts, and a sampling
        // clock left running on a surface nobody is looking at keeps taking
        // screenshots of the desktop for nobody.
        stopSampling()
    }

    private func tick() {
        let pointer = NSEvent.mouseLocation
        if let last = lastPointer, hypot(pointer.x - last.x, pointer.y - last.y) < 0.5 {
            return
        }
        lastPointer = pointer
        // Held down, the pointer is doing something to the frame; a window
        // lighting up under it would be a second answer to the same gesture.
        guard !pressing else { return }
        refreshHover()
    }

    private func refreshHover() {
        // In long mode the window is not in the pointing business at all: the
        // mouse is being ignored on purpose so the wheel reaches the app being
        // scrolled, and a crosshair of ours over it would be this app talking
        // over the one that is actually being used.
        guard mode == .shot else { return }
        let pointer = NSEvent.mouseLocation
        // Over the bar the pointer is a pointer, not a crosshair: there is
        // something there to press, and the shape of the cursor is the cheapest
        // way to say so. The window behind it is not the answer either — a
        // highlight under the button reads as the button selecting it.
        let local = NSPoint(x: pointer.x - screen.frame.minX, y: pointer.y - screen.frame.minY)
        let geometry = bar()
        let overBar = geometry.capsule.contains(local)
            || (panelOpen && geometry.panel.contains(local))
        if overBar {
            setHovered(nil)
            NSCursor.arrow.set()
            return
        }
        // A drawn frame answers for its own edges before the window underneath
        // does: once a rectangle exists the pointer near it is almost always
        // about the rectangle, and lighting a window through it would offer to
        // throw the work away.
        //
        // A chosen window answers for nothing: there is no edge to pull and
        // nothing in it to drag, so the pointer stays a crosshair — a hand on a
        // frame that will not move is the cursor telling a lie.
        if let rect = selection, chosenWindow == nil {
            if let handle = handle(at: local, in: rect) {
                setHovered(nil)
                Self.cursor(for: handle).set()
                return
            }
            if viewRect(rect).contains(local) {
                setHovered(nil)
                NSCursor.openHand.set()
                return
            }
        }
        // The window that has already been chosen is not offered again: it is
        // the answer, and a hover is only ever the question.
        let under = WindowPick.window(at: pointer, in: windows)
        setHovered(under == chosenWindow ? nil : under)
        NSCursor.crosshair.set()
    }

    private func setHovered(_ value: PickableWindow?) {
        guard value != hovered else { return }
        hovered = value
        needsDisplay = true
    }

    // MARK: The drawing

    /// The bar's surface and ink are chosen from the appearance, so a change in
    /// the middle of a capture — the system switching at sunset, or the app's
    /// own switch being moved — has to be a repaint rather than a bar that stays
    /// the colour it was asked for first. AppKit asks here and nowhere else.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Long mode draws the other way round: the window is transparent, the
        // region is a hole, and only what surrounds it is darkened. The person
        // is scrolling the app underneath and has to watch it scroll, so the
        // pixels inside the frame have to be the live screen at full strength —
        // a frozen backdrop there would show the top of the page for ever while
        // the wheels turned.
        if mode == .long, let rect = selection {
            let local = viewRect(rect)
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(rect: local))
            outside.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.56).setFill()
            outside.fill()
            drawBorder(local, strong: true)
            drawBar()
            return
        }

        // The backdrop first, at full strength: everything after this either
        // dims it or lifts a piece of it back out, and both need it there.
        backdropImage.draw(in: bounds)

        // The dimming. One flat pass over everything, then the chosen piece is
        // drawn again on top of it — which is both cheaper and more honest than
        // trying to build an inverse mask, and it means the un-dimmed part is
        // the real pixels rather than a lightened approximation of them.
        //
        // 0.56 rather than something lighter. The first pass used 0.34, at
        // which a dark editor at night looked untouched and the only thing
        // saying a capture was running was the white border; 0.42 fixed that
        // but still left the windows around the chosen one reading as though
        // they were equally available. The number is the difference between
        // "dimmed" and "not what you are pointing at".
        context.setFillColor(NSColor.black.withAlphaComponent(0.56).cgColor)
        context.fill(bounds)

        if let rect = highlightedRect {
            let local = viewRect(rect)
            backdropImage.draw(in: local, from: local, operation: .copy, fraction: 1)
            if readingState != nil {
                // The picture has become words. Showing them inside the region
                // is the whole point of the confirmation step: the question
                // "is this right" cannot be answered about text nobody has
                // seen, and the region is the one place where the text sits on
                // what it came from.
                drawReading(local)
                drawBorder(local, strong: true)
            } else {
                drawBorder(local, strong: selection != nil || previewSelection != nil)
                drawSize(rect, over: local)
                // After the drag, not during it: under a moving hand eight dots
                // are decoration, and the moment they are wanted is the moment
                // the hand stops. They are also the only thing on screen saying
                // a frame that has been drawn can still be changed.
                if (frameIsResizable || previewSelection != nil), !drawingFrame,
                   previewLong == nil {
                    drawHandles(local)
                }
            }
        } else if selection == nil {
            // Nothing chosen and nothing under the pointer: the pointer is over
            // the desktop, and what a click would take is the whole screen.
            // Said rather than guessed at, because a bare screen with no
            // highlight reads as "nothing to capture".
        }

        drawBar()
    }

    /// What is lit: the dragged rectangle if there is one, otherwise the window
    /// under the pointer.
    private var highlightedRect: CGRect? {
        if let previewSelection { return previewSelection }
        if let selection, selection.width >= 1, selection.height >= 1 { return selection }
        if let previewHighlight { return previewHighlight }
        return hovered?.frame
    }

    private func drawBorder(_ rect: NSRect, strong: Bool) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = strong ? 1.5 : 1
        // The frame is the app's own colour, softened: it has to be legible on
        // top of whatever is being captured, and the accent at full strength
        // read as part of the picture rather than as a frame around it
        // (2026-11-02, "那个橙色能不能淡一点儿").
        CDS.claySoftInk.withAlphaComponent(strong ? 1 : 0.8).setStroke()
        path.stroke()
        // A second, darker line outside it so the edge survives on a white
        // picture as well as on a black one. The pale orange carries the edge on
        // dark content; this hairline carries it on paper.
        let shade = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        shade.lineWidth = 1
        NSColor.black.withAlphaComponent(0.45).setStroke()
        shade.stroke()
    }

    /// `820 × 460`, beside the rectangle.
    ///
    /// Inside the corner when the rectangle is at the top of the screen, above
    /// it otherwise — the one place there is no room for a badge is off the top
    /// edge, which is exactly where a rectangle dragged to the top would put it.
    ///
    /// The same softened clay the frame wears, with dark ink on it: the badge is
    /// read at a glance while the hand is still moving, and white on the pale
    /// orange is the one pairing that does not read at all. The dark ground it
    /// used to have said "system overlay"; this one says which app is asking.
    private func drawSize(_ screenRect: CGRect, over local: NSRect) {
        let numbers = "\(Int(screenRect.width.rounded())) × \(Int(screenRect.height.rounded()))"
        // The shape in front of the numbers, and only while one is locked: a
        // badge that always says "free" is a badge with a word nobody reads.
        let text = aspect.ratio == nil ? numbers : "\(aspect.title)  \(numbers)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: CaptureInk.onClay,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = NSSize(width: 7, height: 3)
        let badge = NSSize(width: size.width + padding.width * 2,
                           height: size.height + padding.height * 2)

        let above = local.maxY + 6
        let fitsAbove = above + badge.height <= bounds.height
        let origin = NSPoint(x: local.minX,
                             y: fitsAbove ? above : max(4, local.maxY - badge.height - 6))

        let pill = NSBezierPath(roundedRect: NSRect(origin: origin, size: badge),
                                xRadius: 4, yRadius: 4)
        CDS.claySoftInk.setFill()
        pill.fill()
        (text as NSString).draw(at: NSPoint(x: origin.x + padding.width,
                                            y: origin.y + padding.height),
                                withAttributes: attributes)
    }

    /// Eight dots: four corners, four sides.
    ///
    /// Small and in the frame's own colour rather than the system's white
    /// squares — the frame already says "this is the app that is asking", and
    /// white blocks on a pale orange border read as three different pieces of
    /// chrome. The dark hairline around each dot is the same trick the border
    /// uses: it is what keeps them visible on a white page.
    private func drawHandles(_ rect: NSRect) {
        for handle in Handle.allCases {
            let point = handle.point(in: rect)
            let dot = NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            let path = NSBezierPath(ovalIn: dot)
            CDS.claySoftInk.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// A ✕ in a disc: leaving without a picture.
    ///
    /// Drawn rather than set as a glyph, for the reason the chevron on the ratio
    /// button is drawn: a "✕" is not in every font at every weight, and the ones
    /// that have it sit low in a 22-point circle.
    private func drawClose(_ rect: NSRect, lit: Bool) {
        let disc = NSBezierPath(ovalIn: rect)
        // The bar's ink rather than white: on a light bar a white disc is not a
        // disc, it is nothing at all.
        CaptureInk.ink(effectiveAppearance)
            .withAlphaComponent(lit ? 0.18 : 0.09).setFill()
        disc.fill()
        let cross = NSBezierPath()
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let arm: CGFloat = 3.6
        cross.move(to: NSPoint(x: centre.x - arm, y: centre.y - arm))
        cross.line(to: NSPoint(x: centre.x + arm, y: centre.y + arm))
        cross.move(to: NSPoint(x: centre.x - arm, y: centre.y + arm))
        cross.line(to: NSPoint(x: centre.x + arm, y: centre.y - arm))
        cross.lineWidth = 1.4
        cross.lineCapStyle = .round
        CaptureInk.ink(effectiveAppearance)
            .withAlphaComponent(lit ? 0.95 : 0.7).setStroke()
        cross.stroke()
    }

    /// What was read, drawn inside the region it was read from.
    ///
    /// A sheet rather than a floating panel: the words belong where the picture
    /// was, so the eye compares them with what it remembers of the picture
    /// without being told to. Truncated at the region's edge, because a reading
    /// of a whole page will not fit in a 300-point box and shrinking the type to
    /// fit would be a preview nobody can check.
    ///
    /// The bar carries the count, so what is cut off is still accounted for.
    private func drawReading(_ rect: NSRect) {
        let sheet = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        CaptureInk.panel(effectiveAppearance).setFill()
        sheet.fill()

        let pad: CGFloat = 12
        let box = rect.insetBy(dx: pad, dy: pad)
        // A degenerate box (no room at all) has nothing to draw into; a short
        // one — a single line of small text, say — still gets its one line,
        // centred, rather than a blank panel with the words missing. The old
        // `box.height > 18` test dropped exactly those: the sheet painted, the
        // text did not, so a one-line read showed as an empty block.
        guard box.width > 8 else { return }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.93),
            .paragraphStyle: style,
        ]

        guard let state = readingState else { return }
        if translating {
            draw(L("Translating…"), in: box, attributes: attributes, centred: true)
            return
        }
        switch state {
        case .going:
            draw(L("Reading…"), in: box, attributes: attributes, centred: true)
        case .nothing:
            draw(L("No text found"), in: box, attributes: attributes, centred: true)
        case .found:
            guard let text = shownText else { return }
            let lineHeight: CGFloat = 17
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let room = max(1, Int(box.height / lineHeight))
            // Top-down when there is a line of headroom; centred when the box is
            // shorter than one line, so a single short line still lands inside
            // the sheet instead of above it.
            let oneLineShort = box.height < lineHeight
            for (index, line) in lines.prefix(room).enumerated() {
                let y = oneLineShort
                    ? box.minY + (box.height - lineHeight) / 2
                    : box.maxY - CGFloat(index + 1) * lineHeight
                (String(line) as NSString).draw(in: NSRect(x: box.minX, y: y + 4,
                                                          width: box.width, height: lineHeight),
                                                withAttributes: attributes)
            }
        }
    }

    /// Whether a rectangle is being drawn right now, as opposed to adjusted.
    private var drawingFrame: Bool {
        if case .drawing = press { return true }
        return false
    }

    // MARK: The bar

    /// What the bottom of the screen carries: one line about the gesture and
    /// one button, in one capsule.
    ///
    /// It was a line of words alone, and every choice on it was a key — `R` for
    /// the shape, nothing at all for the rest. Words are the right form for the
    /// gestures, because those need no state: dragging already drags, hovering
    /// already lights a window, and a button for either would teach the opposite
    /// of what is true ("without this, you cannot"). A button is the right form
    /// for the one thing a gesture cannot express — *which shape* — and it is
    /// the only pressable thing in the capsule (2026-11-02).
    ///
    /// The line is not a manual. It says what is still ahead, and gives way to
    /// what is live once something has been decided, so the only permanent words
    /// in the window are two key names at the right. Its width is pinned against
    /// the longer of the two sentences, so the capsule does not jump when a drag
    /// begins.
    private struct Bar {
        var capsule = NSRect.zero
        var line = NSRect.zero
        var lineText = ""
        var divider = NSRect.zero
        var button = NSRect.zero
        var buttonText = ""
        /// The second button: the one that turns the region into something that
        /// keeps growing. It is a button and not a key because "this area will
        /// keep growing" is a kind of capture, not a place — no gesture says it.
        var long = NSRect.zero
        /// The third button: read the words out of the area instead of taking a
        /// picture of it. A button for the same reason 长图 is one — "this area
        /// is a thing to be read" is a kind of capture, and no gesture says it.
        var read = NSRect.zero
        /// The middle of the bar while a long capture runs, where the two
        /// buttons were: one number, and the pill that ends the capture.
        var middle = NSRect.zero
        var middleText = ""
        /// The pill that ends a long capture. It is the only pressable thing
        /// while one runs, and the only way out that does not need a keyboard —
        /// the Return that ends it is a key borrowed from the page, and a
        /// borrowed key should not be the only way out.
        var done = NSRect.zero
        var doneText = ""
        /// The ✕ beside it: leaving without a picture, for the same audience.
        /// Asked for after living with the pill for an hour — the only other way
        /// to abandon a long capture was to finish it and delete the card.
        var close = NSRect.zero
        /// The fourth button: the same area, translated.
        ///
        /// A kind of capture in its own right — the words come back in another
        /// language and stay on the screen, and nothing is hung on the line. It
        /// is a separate button rather than a switch on a reading because the
        /// two asks are different asks: "give me this text" and "tell me what
        /// this says" want different things afterwards.
        var translate = NSRect.zero
        /// The fifth: take it, and open it in the editor.
        ///
        /// A different axis from the four before it — they say what this area
        /// *is*, this one says what happens to it afterwards — and it sits at
        /// the end of the group for that reason. One press, because a shot and
        /// then a hunt for the editor is two.
        var edit = NSRect.zero
        /// The last button: the same area as last time, taken again.
        ///
        /// An action rather than a kind of capture, so it never fills and it
        /// has no key: the other four describe what this rectangle *is*, and
        /// this one says "that rectangle again", which cannot be said before
        /// a rectangle exists. It sits last because it is the only button here
        /// that does not change what the next drag means.
        var again = NSRect.zero
        var keysText = ""
        var keys = NSRect.zero
        var panel = NSRect.zero
        var options: [(CropAspect, NSRect)] = []
    }

    private static let barHeight: CGFloat = 34
    private static let barPadding: CGFloat = 13
    private static let barGap: CGFloat = 10
    /// The ✕ beside the pill. Round, and small enough to sit beside a 26-point
    /// pill without becoming a second button on equal footing — it is the way
    /// out, not the way on.
    private static let closeSize: CGFloat = 22
    private static let lineFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    private static let buttonFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let keysFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    private static let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The buttons are chips now, and the numbers are the editor's own: 30 × 26
    /// with four points between them, the same box `ToolChip` wears. Two bars in
    /// one app that differ by a point read as two different apps.
    private static let chipWidth: CGFloat = 30
    private static let chipHeight: CGFloat = 26
    private static let chipGap: CGFloat = 4
    /// The key, in the corner, at the size of a footnote to a footnote — copied
    /// from `ToolChip.drawHint` for the same reason: it is a remark about the
    /// button, not a second label on it.
    private static let hintFont = NSFont.systemFont(ofSize: 6.5, weight: .semibold)

    /// Whether the ratio panel is showing. Set by the button, cleared by a
    /// choice or by any press outside it.
    var panelOpen = false

    /// The geometry the tool tips were last registered for. See `refreshToolTips`.
    private var toolTipSignature = ""

    /// The words the line carries, one per state. Named once because the layout
    /// measures all of them to pin the capsule's width — a capsule that resized
    /// as the state changed would move under the hand that is using it.
    private var lineSettled: String { L("Drag an edge to adjust · Return to capture") }
    /// The whole screen chosen with Space, where "drag an edge" is true but not
    /// the first thing to say: nothing is dimmed (there is nothing outside the
    /// selection to dim), so the words are most of what says the screen *is*
    /// selected.
    private var lineWholeScreen: String { L("Whole screen · Return to capture") }
    /// A chosen window, where "drag an edge to adjust" would be a lie: its frame
    /// is the window's and nothing here may move it. What is left to say is
    /// only what the frame is.
    private var lineWindow: String { L("Window · Return to capture") }
    private var lineWaiting: String { L("Drag out an area · click a window · Space for the whole screen") }
    private var lineArmed: String { L("Drag the area that should keep growing") }
    private var lineGrowing: String { L("Scroll up or down · Return when done") }
    private var lineReadArmed: String { L("Drag the area whose words you want") }
    private var lineTranslateArmed: String { L("Drag the area to translate") }
    private var lineReading: String { L("The words in this area") }
    private var lineTranslating: String { L("Translating…") }
    private var lineTranslated: String { L("The words, in the other language") }
    private var lineTranslateFailed: String { L("Those words could not be translated") }
    private var lineTranslateUnsure: String { L("Cannot tell which language these words are in") }
    private var lineTranslateUnsupported: String {
        L("This Mac cannot translate between those two languages")
    }
    private var lineTranslateNoop: String { L("Those words are already in this language") }

    private func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Whether the region is one that keeps growing — either for real, or in
    /// the harness, which has no page to scroll.
    private var growing: Bool { mode == .long || previewLong != nil }

    /// Every line the bar can ever say, for the one purpose of pinning its
    /// width.
    ///
    /// The notes are in here while none of them is showing, and that is the
    /// point: a note arrives when a scroll goes the wrong way or the page runs
    /// out, which is exactly mid-capture, with a hand already on the way to the
    /// Done pill. Measuring them only once they appear would widen the capsule
    /// and slide the pill away from that hand.
    private var measuredLines: [String] {
        [lineSettled, lineWholeScreen, lineWindow, lineWaiting, lineArmed, lineReadArmed,
         lineTranslateArmed,
         lineGrowing, lineReading, lineTranslating, lineTranslated, lineTranslateFailed,
         lineTranslateNoop, lineTranslateUnsure, lineTranslateUnsupported,
         longNote ?? "", previewNote ?? ""] + LongStitcher.notes
    }

    /// Where everything in the bar sits, in this view's own coordinates.
    ///
    /// Computed on demand rather than cached in the draw: a hit test and the
    /// picture it is clicking on have to be the same geometry, and two copies
    /// of it are two copies that can disagree.
    private func bar() -> Bar {
        var out = Bar()
        let settled = selection != nil || previewSelection != nil
        if let note = longNote ?? previewNote {
            out.lineText = note
        } else if translating {
            out.lineText = lineTranslating
        } else if let refusal {
            switch refusal {
            case .unsure: out.lineText = lineTranslateUnsure
            case .unsupported: out.lineText = lineTranslateUnsupported
            case .failed: out.lineText = lineTranslateFailed
            }
        } else if translateNoop {
            out.lineText = lineTranslateNoop
        } else if readingState != nil {
            out.lineText = translationText == nil ? lineReading : lineTranslated
        } else if growing {
            out.lineText = lineGrowing
        } else if readArmed {
            out.lineText = lineReadArmed
        } else if translateArmed {
            out.lineText = lineTranslateArmed
        } else if longArmed {
            out.lineText = lineArmed
        } else if chosenWindow != nil {
            // Before the whole-screen test, because a window may fill the
            // display: whichever of the two was chosen is what the line is
            // answering, and the choice is the fact — not the rectangle.
            out.lineText = lineWindow
        } else if selection == screen.frame, mode == .shot {
            out.lineText = lineWholeScreen
        } else {
            out.lineText = settled ? lineSettled : lineWaiting
        }
        let lineWidth = measuredLines
            .map { textWidth($0, Self.lineFont) }.max() ?? 200
        // The one chip that carries a value, and therefore the only one that is
        // not a square: a symbol says "this is a shape", the word says *which*,
        // the chevron says it opens a menu, and the key sits in the corner like
        // every other chip's. Pinned to the widest title, so a chip that
        // resizes as the shape changes does not move the five beside it.
        out.buttonText = aspect.title
        let valueWidth = (CropAspect.allCases
            .map { textWidth($0.title, Self.buttonFont) }.max() ?? 40)
        let buttonWidth = 8 + 13 + 5 + valueWidth + 3 + 9 + 8
        // Every other chip is the same box, so one number each is all the row
        // needs — and the keys live in their corners now, which is why the
        // legend that used to spell them out is only the way out.
        out.middleText = middleLabel
        out.keysText = "esc"
        let keysWidth = textWidth(out.keysText, Self.keysFont)
        let chipCount = 4 + (againShown ? 1 : 0)

        let width = Self.barPadding * 2 + lineWidth + Self.barGap + 1 + Self.barGap
            + buttonWidth + CGFloat(chipCount) * (Self.chipGap + Self.chipWidth)
            + Self.barGap + keysWidth
        // Above the Dock rather than at a fixed 24 points, which is where the
        // first draft put it and where the Dock then sat on top of it.
        let dockInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
        out.capsule = NSRect(x: ((bounds.width - width) / 2).rounded(),
                             y: dockInset + 20,
                             width: width, height: Self.barHeight)
        let midY = out.capsule.midY
        var x = out.capsule.minX + Self.barPadding
        out.line = NSRect(x: x, y: midY - 8, width: lineWidth, height: 16)
        x += lineWidth + Self.barGap
        out.divider = NSRect(x: x, y: midY - 8, width: 1, height: 16)
        x += 1 + Self.barGap
        // The run of chips: the ratio one first, then the four actions, ending on
        // the one that hands the picture over. Four points between them and ten
        // before the `esc` — the tight gap is what makes them read as one row of
        // the same kind of thing, which is the whole reason for borrowing the
        // editor's numbers.
        func chip(_ x: CGFloat, _ width: CGFloat) -> NSRect {
            NSRect(x: x, y: midY - Self.chipHeight / 2, width: width, height: Self.chipHeight)
        }
        out.button = chip(x, buttonWidth)
        x += buttonWidth + Self.chipGap
        out.long = chip(x, Self.chipWidth)
        x += Self.chipWidth + Self.chipGap
        out.read = chip(x, Self.chipWidth)
        x += Self.chipWidth + Self.chipGap
        out.translate = chip(x, Self.chipWidth)
        x += Self.chipWidth + Self.chipGap
        // 重载 comes before 编辑. The row now ends on the button that hands the
        // picture over, so the last thing under the hand after choosing a shape
        // is the one that finishes the job; 重载 sits one place earlier because
        // it throws the choice away and starts again.
        if againShown {
            out.again = chip(x, Self.chipWidth)
            x += Self.chipWidth + Self.chipGap
        }
        out.edit = chip(x, Self.chipWidth)
        // The keys slot starts a full gap past whichever chip is last, which is
        // also where the pill is anchored below — one end for both, so a press
        // meant for one cannot land on the other. 编辑 is always drawn and is
        // now always last, so this no longer has to ask which chip that is.
        x = out.edit.maxX + Self.barGap
        // The pill and the ✕ hang off the far end of the slot the buttons share,
        // which is the end 编辑 occupies. Anchored to `译` instead — where they
        // were before these buttons existed — they would sit over a button that
        // is no longer last, and the two would trade presses.
        let lastButton = out.edit.maxX
        out.middle = NSRect(x: out.button.minX, y: midY - 8,
                            width: lastButton - out.button.minX, height: 16)
        // Pinned to the far edge of the slot the buttons share. The height
        // beside it gains a digit as the picture grows, and a button that slides
        // along with a number is a button that has to be aimed at twice.
        //
        // The ✕ is placed from the pill's edge and not from what is drawn: the
        // pill is absent while a reading is still going, and a ✕ that stood in
        // one place and then moved is a ✕ to miss at the only moment it is
        // wanted.
        out.doneText = doneLabel
        let doneWidth = textWidth(out.doneText, Self.buttonFont) + 26
        out.done = NSRect(x: lastButton - doneWidth, y: midY - 13,
                          width: doneWidth, height: 26)
        out.close = NSRect(x: out.done.minX - Self.barGap - Self.closeSize,
                           y: midY - Self.closeSize / 2,
                           width: Self.closeSize, height: Self.closeSize)
        // The way out, and the only key still spelled out: every button now
        // carries its own letter in its corner, so a legend listing them would
        // be the same fact told twice, in the place with the least room.
        let shownKeys = textWidth(out.keysText, Self.keysFont)
        out.keys = NSRect(x: x + keysWidth - shownKeys, y: midY - 7,
                          width: shownKeys, height: 14)

        guard panelOpen, mode == .shot else { return out }
        // Three by three: the nine shapes are exactly a square, and a menu of
        // nine rows for something chosen by silhouette is a menu read as a list.
        let chipWidth = (CropAspect.allCases
            .map { textWidth($0.title, Self.chipFont) }.max() ?? 40) + 26
        let chipHeight: CGFloat = 26
        let space: CGFloat = 6
        let pad: CGFloat = 10
        let panelWidth = pad * 2 + chipWidth * 3 + space * 2
        let panelHeight = pad * 2 + chipHeight * 3 + space * 2
        let panelX = min(max(8, out.button.midX - panelWidth + 16), bounds.width - panelWidth - 8)
        out.panel = NSRect(x: panelX, y: out.capsule.maxY + 8,
                           width: panelWidth, height: panelHeight)
        for (index, option) in CropAspect.allCases.enumerated() {
            let rect = NSRect(x: panelX + pad + CGFloat(index % 3) * (chipWidth + space),
                              y: out.panel.maxY - pad - chipHeight
                                - CGFloat(index / 3) * (chipHeight + space),
                              width: chipWidth, height: chipHeight)
            out.options.append((option, rect))
        }
        return out
    }

    /// `1240 pt` — how tall the picture has grown, in points.
    ///
    /// Points rather than pixels: the number is read while scrolling, and what
    /// it has to compare against is the text on the screen behind it, which is
    /// measured in points too.
    private var middleLabel: String {
        if translating { return "" }
        if let translationText { return "\(translationText.count) \(L("characters"))" }
        if let state = readingState {
            switch state {
            case .going: return L("Reading…")
            case .nothing: return L("No text found")
            case .found(let text): return "\(text.count) \(L("characters"))"
            }
        }
        if let previewLong { return "\(previewLong) pt" }
        guard mode == .long, stitcher.count > 0 else { return "" }
        let points = Int((Double(stitcher.height) / screen.backingScaleFactor).rounded())
        return "\(points) pt"
    }

    /// What the pill says, which is what pressing it does.
    ///
    /// `完成` ends a picture that keeps growing, `确认` agrees with words that
    /// will hang on the line, `复制` takes a translation away. Three acts, three
    /// words, and the pill is the only place any of them is named.
    private var doneLabel: String {
        if readingPurpose == .translate {
            return copyable ? L("Copy") : L("Done")
        }
        if let state = readingState, case .found = state { return L("Confirm") }
        return L("Done")
    }

    /// Whether there is something to take away.
    ///
    /// Always, once there are words: the translation when one arrived, and the
    /// words themselves when none did. A refusal is said on the line and is
    /// still no reason to leave the person holding nothing — and a pill that
    /// vanishes is a button that appears not to work, which is how this one was
    /// reported.
    private var copyable: Bool {
        guard !translating else { return false }
        if case .found = readingState { return true }
        return false
    }

    /// Whether there is anything for the pill to do.
    ///
    /// Ending a long capture always is. Confirming words only once they exist:
    /// while the read is still going there is nothing to agree with, and when it
    /// found nothing a pill saying `完成` would be a pill that lies. Copying a
    /// translation only once it has arrived, for the same reason — while the
    /// engine is working there is nothing to take away, and saying so is the
    /// line's job.
    private var pillLive: Bool {
        // `growing` rather than `mode == .long`: the harness has no long mode to
        // be in — it sets `previewLong` and renders the same bar — and a pill
        // that exists on a real screen and not in a picture of one is a preview
        // that cannot be trusted about the one thing it is for.
        if growing { return true }
        if let state = readingState, case .found = state {
            return readingPurpose == .translate ? copyable : true
        }
        return false
    }

    /// The bar's capsule and its Done pill, in screen coordinates.
    ///
    /// The controller lays a window of its own over that capsule, because the
    /// overlay ignores the mouse for the length of a long capture — that is how
    /// the wheel reaches the app being scrolled — so a button drawn in here
    /// would be a picture of a button. Handed out as geometry rather than as a
    /// window so the surface keeps knowing where its own bar is: two copies of
    /// that arithmetic would be two answers to "did the click land on it".
    ///
    /// Nil unless something is growing. The harness sets `previewLong` and reads
    /// this, so the geometry it draws is answered by the same arithmetic the
    /// controller uses to place the window — a harness with its own copy of that
    /// arithmetic would be able to show a bar the app cannot produce.
    var longBarOnScreen: (capsule: NSRect, done: NSRect, close: NSRect)? {
        guard growing else { return nil }
        let bar = bar()
        guard !bar.done.isEmpty else { return nil }
        let origin = screen.frame.origin
        return (bar.capsule.offsetBy(dx: origin.x, dy: origin.y),
                bar.done.offsetBy(dx: origin.x, dy: origin.y),
                bar.close.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// Where the shot state's `识别` button sits, and where the key legend
    /// starts, in screen coordinates.
    ///
    /// Handed out for the same reason `longBarOnScreen` is: the harness has to
    /// ask the live arithmetic rather than keep a copy of it. Two answers to
    /// "where is the button" is a button that is drawn in one place and pressed
    /// in another.
    var shotBarOnScreen: (capsule: NSRect, ratio: NSRect, long: NSRect, read: NSRect,
                          translate: NSRect, edit: NSRect, again: NSRect, keys: NSRect)? {
        guard mode == .shot, readingState == nil else { return nil }
        let bar = bar()
        guard !bar.read.isEmpty else { return nil }
        let origin = screen.frame.origin
        return (bar.capsule.offsetBy(dx: origin.x, dy: origin.y),
                bar.button.offsetBy(dx: origin.x, dy: origin.y),
                bar.long.offsetBy(dx: origin.x, dy: origin.y),
                bar.read.offsetBy(dx: origin.x, dy: origin.y),
                bar.translate.offsetBy(dx: origin.x, dy: origin.y),
                bar.edit.offsetBy(dx: origin.x, dy: origin.y),
                bar.again.offsetBy(dx: origin.x, dy: origin.y),
                bar.keys.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// Where the reading state's pill and ✕ sit, in screen coordinates.
    ///
    /// Handed out for the same reason the two above are: the harness has to ask
    /// the live arithmetic instead of keeping a copy of it. A button drawn in
    /// one place and pressed in another is exactly what a second copy of this
    /// arithmetic buys.
    var readingBarOnScreen: (capsule: NSRect, close: NSRect, done: NSRect)? {
        guard readingState != nil, !translating else { return nil }
        let bar = bar()
        let origin = screen.frame.origin
        return (bar.capsule.offsetBy(dx: origin.x, dy: origin.y),
                bar.close.offsetBy(dx: origin.x, dy: origin.y),
                bar.done.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// A press on the bar, for the harness.
    ///
    /// The same arithmetic the mouse goes through, called directly because a
    /// harness has no pointer: `mouseDown` needs an event, and building one for
    /// a view that is not in a window proves nothing about the window server.
    func takeBarClickForTesting(at local: NSPoint) -> Bool { takeBarClick(at: local) }

    /// Leaves a drawn rectangle behind, for the harness.
    ///
    /// The harness has no hand. Everything downstream of the drag — which door
    /// was chosen, which area is cut, whether the engine is asked — is the same
    /// code either way, and this is the one seam that needs a stand-in.
    func selectForTesting(_ rect: CGRect) { selection = rect }

    /// Puts a remembered frame back, as if it had just been dragged out.
    ///
    /// Not a capture and not a decision: the rectangle arrives with its handles
    /// and the bar goes back to saying "adjust it, then Return", which is the
    /// state a hand-drawn frame leaves behind. Everything that answers a frame
    /// afterwards — double-click, Return, the doors, the eight handles, esc —
    /// answers this one by the same code, because it is the same state. A
    /// restored frame that had its own rules would be a second definition of
    /// what a frame is.
    ///
    /// The point of arriving rather than firing: the case this is for is a page
    /// that has *moved*, and a picture taken of a remembered rectangle without
    /// showing it to anyone is a picture taken confidently of the wrong thing.
    func restore(_ rect: CGRect) {
        guard mode == .shot, readingState == nil else { return }
        selection = rect
        // After the assignment, not before: the `didSet` above puts every light
        // out on a change of frame, and this is the one change that lights it.
        if selection == rect { againShowing = true }
        press = .idle
        dragged = false
        barPress = false
        hovered = nil
        needsDisplay = true
    }

    /// The pointer is over the bar, or no longer is.
    ///
    /// Reported by the bar's own window, which is the only window that can see
    /// the pointer while a long capture runs. Two things follow from it, and
    /// both are about the press that ends the capture being swallowed by
    /// something of ours rather than landing on the page behind it:
    ///
    /// - the pill lights up, because a background app cannot change the cursor
    ///   and this is the only "pressable" signal left;
    /// - this window stops ignoring the mouse, so a press on the bar reaches it
    ///   instead of falling through. That matters because the bar's window is
    ///   the one window whose presses have been unreliable: a pointer crossing
    ///   it arrives (tracking areas are the window server's work) while a click
    ///   does not. This window takes clicks for a living — it is the one the
    ///   whole drag-a-rectangle gesture happens in.
    ///
    /// - Parameter point: the pointer in screen coordinates, or nil once it has
    ///   left the bar. Converted here rather than by the caller: `bar()` answers
    ///   in this view's space, and one place knowing how screen space relates to
    ///   it is one place to get it wrong.
    func setPointerOnBar(_ point: NSPoint?) {
        let origin = screen.frame.origin
        let local = point.map { NSPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        let geometry = bar()
        let inside = local.map { geometry.capsule.contains($0) } ?? false
        let onPill = local.map { geometry.done.contains($0) } ?? false
        let onClose = local.map { geometry.close.contains($0) } ?? false
        if mode == .long {
            window?.ignoresMouseEvents = !inside
        }
        guard doneHover != onPill || closeHover != onClose else { return }
        doneHover = onPill
        closeHover = onClose
        needsDisplay = true
    }

    private func drawBar() {
        let bar = bar()
        refreshToolTips(bar)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()

        let capsule = NSBezierPath(roundedRect: bar.capsule,
                                   xRadius: Self.barHeight / 2, yRadius: Self.barHeight / 2)
        // The editor's floating surface, in whichever appearance the app is
        // wearing. The bar used to be one hardcoded dark colour, which made a
        // light-mode app with a black bar in the corner of every capture.
        CaptureInk.surface(effectiveAppearance).setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.13).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        // Centred in its slot rather than left-aligned in it. The slot is pinned
        // to the widest sentence so the buttons never move; left-aligned, that
        // pin shows up as a hole on the right of every short sentence, which is
        // what "右边老是这么空" was. Centred, the same slack is split in two and
        // reads as padding. The sentence is also shorter than it was — see the
        // two translate refusals, which used to be the widest thing here and
        // appeared about once a week.
        draw(bar.lineText, in: bar.line,
             attributes: [.font: Self.lineFont,
                          .foregroundColor: CaptureInk.ink(effectiveAppearance)
                              .withAlphaComponent(0.86)],
             centred: true)

        CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.16).setFill()
        bar.divider.fill()

        if collapsed {
            // The height on the left of the slot the buttons used to fill, the
            // way out on the right.
            let numbers = NSRect(x: bar.button.minX, y: bar.middle.minY,
                                 width: max(0, bar.close.minX - Self.barGap - bar.button.minX),
                                 height: bar.middle.height)
            draw(bar.middleText, in: numbers,
                 attributes: [.font: Self.buttonFont,
                              .foregroundColor: CaptureInk.ink(effectiveAppearance)
                                  .withAlphaComponent(0.88)],
                 centred: true)

            // The one pressable thing that changes what happens, and the only
            // way forward that does not need a keyboard. Clay because it is the
            // thing to press. The ring on hover is the only pointer feedback
            // this app can give here: while a long capture runs it is not
            // frontmost, and a background app is not allowed to set the cursor,
            // so the pill has to say "pressable" by looking different.
            if pillLive {
                let pill = NSBezierPath(roundedRect: bar.done, xRadius: 7, yRadius: 7)
                CDS.clayInk.setFill()
                pill.fill()
                if doneHover {
                    // White on clay in both appearances: the ring is drawn on the
                    // pill rather than on the bar, so the bar's ink is not its
                    // ink — a near-black ring on clay in light mode would read as
                    // a pressed border rather than as "this is the thing".
                    NSColor.white.withAlphaComponent(0.55).setStroke()
                    pill.lineWidth = 1.5
                    pill.stroke()
                }
                draw(bar.doneText, in: bar.done,
                     attributes: [.font: Self.buttonFont,
                                  .foregroundColor: CaptureInk.onClay],
                     centred: true)
            }

            // The ✕, which is never the thing to do and is always available. It
            // is drawn whether or not the pill is, so the way out does not
            // appear and disappear while a read finishes.
            drawClose(bar.close, lit: closeHover)
        } else {
            // Six chips from the editor's own vocabulary: symbol, key in the
            // corner, no words. The words were the reason the capsule was wide
            // enough to read as a paragraph with a toolbar on the end; a symbol
            // says the same thing in 30 points, and the letter in the corner is
            // the only part of this bar that a person has to be taught.
            drawRatioChip(bar.button)
            // The armed chip fills, exactly the way the ratio chip fills when a
            // shape is locked. One rule for the whole bar: filled means "this
            // changes what the next drag means" — so pressing L, W or T has to
            // light the button it stands for, or the key is the only thing on
            // screen saying anything happened. Reported the day after the icons
            // landed, and rightly: `R` filled its chip and the other three keys
            // looked like they had done nothing.
            drawChip(bar.long, symbol: CaptureSymbol.long, key: "L", picked: isPicked(.long))
            drawChip(bar.read, symbol: CaptureSymbol.read, key: "W", picked: isPicked(.read))
            drawChip(bar.translate, symbol: CaptureSymbol.translate, key: "T",
                     picked: isPicked(.translate))
            // 重载 before 编辑, the same order the row is laid out in. The one
            // that ends nothing comes first; the one that takes the picture away
            // is last, at the end of the row.
            //
            // `A` for again. It is the one key here that is not about the next
            // drag but about ending this whole capture, so it is drawn even
            // though the chip never fills: a key nobody can see is a key nobody
            // presses. The letter choice is a mnemonic like the others (`L`
            // long, `W` words, `T` translate, `R` ratio) — and bare rather than
            // global for the same reason they are.
            // `A` for again, and the one chip whose fill means something the
            // other five cannot: "the frame you are looking at came from the
            // last capture". It stays lit for as long as that is true.
            if againShown {
                drawChip(bar.again, symbol: CaptureSymbol.again, key: "A", picked: againShowing)
            }
            // `E` for edit, the last of the five mnemonic keys. It ends the
            // capture the way Return does, so it is not a mode either — but it
            // is the one key that says what happens *after* the picture lands,
            // which is the whole difference between this button and Return.
            drawChip(bar.edit, symbol: CaptureSymbol.edit, key: "E")
        }

        draw(bar.keysText, in: bar.keys,
             attributes: [.font: Self.keysFont,
                          .foregroundColor: CaptureInk.ink(effectiveAppearance)
                              .withAlphaComponent(0.55)])

        guard panelOpen, mode == .shot else { return }
        let panel = NSBezierPath(roundedRect: bar.panel, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        CaptureInk.panel(effectiveAppearance).setFill()
        panel.fill()
        NSGraphicsContext.restoreGraphicsState()
        CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.12).setStroke()
        panel.lineWidth = 1
        panel.stroke()
        for (option, rect) in bar.options {
            let chip = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            let picked = option == aspect
            (picked ? CDS.clayInk
                    : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.07)).setFill()
            chip.fill()
            draw(option.title, in: rect,
                 attributes: [.font: Self.chipFont,
                              .foregroundColor: picked
                                  ? CaptureInk.onClay
                                  : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.9)],
                 centred: true)
        }
    }

    /// One line of text placed inside a rect: centred vertically, and centred
    /// across the rect when `centred`, left-aligned otherwise.
    private func draw(_ text: String, in rect: NSRect,
                      attributes: [NSAttributedString.Key: Any], centred: Bool = false) {
        let width = (text as NSString).size(withAttributes: attributes).width
        let height = (text as NSString).size(withAttributes: attributes).height
        let x = centred ? rect.midX - width / 2 : rect.minX
        (text as NSString).draw(at: NSPoint(x: x, y: rect.midY - height / 2),
                                withAttributes: attributes)
    }

    // MARK: Glyphs

    /// Whether the chips say which key they answer to.
    ///
    /// The editor's switch, not a second one of this app's own: two settings for
    /// "show me the letters" would be two answers to one question, and the one
    /// that is off would look like a bug in the bar that ignores it. Off, the
    /// letters go — and the legend that used to spell them out went with them,
    /// so a hint turned off here is a hint turned off everywhere.
    private var showKeys: Bool { ShortcutHints.isEnabled }

    /// The symbol cache, keyed by what actually changes the picture.
    ///
    /// The bar redraws on every hover, and a redraw that re-asks the system for
    /// six symbol images is a redraw doing work nothing asked for. Keyed by
    /// symbol, size and ink rather than by a dictionary of one entry per button:
    /// the same symbol at the same size is the same picture, whichever chip is
    /// drawing it.
    private static var glyphs: [String: NSImage] = [:]

    /// A symbol, already in the ink it will be drawn with.
    ///
    /// The bar is hand-drawn, so a template image would come out black: template
    /// tinting belongs to `NSButton`'s cell, and there is no button here.
    /// `paletteColors` is the system's own way to say "draw this symbol in this
    /// colour" — one configuration instead of a compositing pass over a copy.
    private static func glyph(_ symbol: String, pointSize: CGFloat, ink: NSColor) -> NSImage? {
        let key = "\(symbol)-\(pointSize)-\(inkCacheKey(ink))"
        if let cached = glyphs[key] { return cached }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        let image = base.withSymbolConfiguration(config) ?? base
        glyphs[key] = image
        return image
    }

    /// Which ink a cached symbol was baked in, as a string.
    ///
    /// The colour used to be a bool — "dark, because it is on clay" — and a bool
    /// cannot tell white from near-black, which are now the two answers for the
    /// same chip in two appearances. Keyed by the resolved components, a symbol
    /// drawn in the light appearance is never handed back for the dark one.
    private static func inkCacheKey(_ ink: NSColor) -> String {
        let rgb = ink.usingColorSpace(.sRGB) ?? ink
        return String(format: "%.3f/%.3f/%.3f/%.3f", rgb.redComponent, rgb.greenComponent,
                      rgb.blueComponent, rgb.alphaComponent)
    }

    /// Whether a chip is filled, and therefore whether the thing it names is the
    /// thing the next drag will do.
    ///
    /// One place, asked by the drawing and by the harness both. `R` filled its
    /// chip and `L`/`W`/`T` did not, which made three keys that looked like they
    /// had done nothing at all — and the fix is only a fix if all four ask the
    /// same question from now on.
    private func isPicked(_ chip: Choice) -> Bool {
        switch chip {
        case .ratio: return aspect != .free
        case .long: return longArmed
        case .read: return readArmed
        case .translate: return translateArmed
        }
    }

    /// The chips that can be filled. `编辑` and `重截` cannot: one ends the
    /// capture by taking it, the other by putting a frame back, and neither
    /// changes what the next drag means.
    enum Choice: String, CaseIterable {
        case ratio, long, read, translate
    }

    /// The filled chips, for the harness.
    ///
    /// A 15% clay wash on a dark capsule is not something a check can see in a
    /// bitmap it does not have — and the failure this guards against ("I pressed
    /// L and nothing lit up") is invisible in prose as well.
    var pickedChipsForTesting: [String] {
        Choice.allCases.filter(isPicked).map(\.rawValue)
    }

    /// Whether `重截` is lit at this instant, for the harness.
    ///
    /// A third kind of light, beside "armed" and "on clay": one that belongs to
    /// the frame on screen rather than to a mode, so it is asked for after the
    /// frame is there — and asked again after the frame changes.
    var againShowingForTesting: Bool { againShowing }

    /// Arms a mode without a key press, for the layout harness.
    ///
    /// The picture is the only place the wash can be judged, and there is no
    /// keyboard in a render.
    func armForTesting(_ name: String?) {
        switch name {
        case "long": longArmed = true
        case "read": readArmed = true
        case "translate": translateArmed = true
        // Not an arming either, but it has to be holdable for a photograph:
        // `restore` is what normally lights this, and a preview has no click.
        case "again": againShowing = true
        default: break
        }
    }

    /// A chip: the rounded box, its symbol, and its key.
    ///
    /// One function for the five actions, because they differ in exactly two
    /// things — which symbol and which letter — and five drawings of the same
    /// box is five chances for one of them to be a point off. `picked` is clay
    /// for the same reason the ratio button is: filled means "this changes what
    /// the next drag means", and an action that fills would be claiming a state
    /// it does not have.
    private func drawChip(_ rect: NSRect, symbol: String, key: String?, picked: Bool = false) {
        let box = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (picked ? CDS.clayInk
                : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.10)).setFill()
        box.fill()
        let ink = picked ? CaptureInk.onClay
                         : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.92)
        if let image = Self.glyph(symbol, pointSize: 14, ink: ink) {
            let size = image.size
            image.draw(in: NSRect(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
        if let key, showKeys {
            // On clay the letter has to go dark, for the same reason the icon
            // does: white on clay is not faint, it is gone.
            drawHint(key, in: rect, onClay: picked)
        }
    }

    /// The key, bottom right, in the faintest ink that still holds at 6.5 pt.
    ///
    /// Drawn last and over the symbol, which is how the editor's chips do it: on
    /// a glyph that fills its box the letter sits on the shape rather than
    /// beside it, and at this size that is the difference between a hint and a
    /// smudge. `onClay` is the one chip whose ground is clay rather than ink,
    /// and a white letter on clay is not a faint hint — it is an absent one.
    private func drawHint(_ key: String, in rect: NSRect, onClay: Bool = false) {
        let ink = onClay
            ? CaptureInk.onClay.withAlphaComponent(0.55)
            : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.5)
        let string = NSAttributedString(string: key, attributes: [
            .font: Self.hintFont,
            .foregroundColor: ink,
        ])
        string.draw(at: NSPoint(x: rect.maxX - string.size().width - 3, y: rect.minY + 2))
    }

    /// What a chip is called, and the sentence a person needs to hear it in.
    ///
    /// The editor's chips carry a `toolTip` and this bar is the same row of
    /// symbols, so it owes the same answer: an arrow going down to a line is
    /// obvious once it has been used and means nothing before. The words the
    /// buttons used to wear survive here, where they cost no width.
    private func chipName(at local: NSPoint) -> String? {
        // Nothing is drawn but a readout while a long capture runs or a reading
        // is waiting, and a tip naming a button that is not there is a tip about
        // a button that was.
        guard !collapsed else { return nil }
        let bar = bar()
        if bar.button.contains(local) { return L("Ratio · the shape of the frame") }
        if bar.long.contains(local) { return L("Long · scroll down, Return when done") }
        if bar.read.contains(local) { return L("Text · the words in the area") }
        if bar.translate.contains(local) { return L("Translate · the same words, another language") }
        if bar.edit.contains(local) { return L("Edit · take it and open the editor") }
        if againShown, bar.again.contains(local) { return L("Again · put the last frame back") }
        return nil
    }

    /// One tool tip over the bar, re-registered only when the bar moves.
    ///
    /// `drawBar` runs on every hover, and adding and removing tool tips at that
    /// rate is a flicker rather than a feature. One region rather than six
    /// because the answer depends on the point, and the point is asked for
    /// fresh in `view(_:stringForToolTip:point:userData:)`.
    private func refreshToolTips(_ bar: Bar) {
        let signature = "\(bar.capsule.minX)|\(bar.capsule.minY)|\(bar.capsule.width)|\(againShown)"
        guard signature != toolTipSignature else { return }
        toolTipSignature = signature
        removeAllToolTips()
        addToolTip(bar.capsule, owner: self, userData: nil)
    }

    /// The tool tip owner's one question, answered from the point.
    ///
    /// Not an `override`: AppKit asks this through the informal `NSToolTipOwner`
    /// protocol, which `NSView` does not declare in Swift — the selector is the
    /// contract, and `addToolTip` above is what makes the call happen.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        chipName(at: point) ?? ""
    }

    /// The ratio chip: the one button that carries a value.
    ///
    /// A symbol alone would say "a shape" and stop there, which is precisely the
    /// question this chip is not about — what it answers is *which* shape. So it
    /// keeps the word, gains the symbol that says what kind of setting it is,
    /// and keeps its chevron: the value says where it stands, the chevron says
    /// there are others. Its key sits in the corner like every neighbour's.
    private func drawRatioChip(_ rect: NSRect) {
        // Filled clay only while a shape is locked: an always-clay chip would be
        // claiming a state the free shape does not have.
        let locked = isPicked(.ratio)
        let box = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (locked ? CDS.clayInk
                : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.10)).setFill()
        box.fill()
        let ink = locked ? CaptureInk.onClay
                         : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.92)
        if let image = Self.glyph(CaptureSymbol.ratio, pointSize: 13, ink: ink) {
            let size = image.size
            image.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
        draw(aspect.title,
             in: NSRect(x: rect.minX + 8 + 13 + 5, y: rect.minY,
                        width: rect.width - (8 + 13 + 5) - (3 + 9 + 8),
                        height: rect.height),
             attributes: [.font: Self.buttonFont, .foregroundColor: ink])

        // A drawn chevron rather than a glyph: "▾" is not in every font, and the
        // one that has it sets it at the wrong weight for a 26-point box.
        let chevron = NSBezierPath()
        let centre = NSPoint(x: rect.maxX - 12, y: rect.midY + 1.5)
        chevron.move(to: NSPoint(x: centre.x - 3.5, y: centre.y + 2))
        chevron.line(to: NSPoint(x: centre.x, y: centre.y - 1.5))
        chevron.line(to: NSPoint(x: centre.x + 3.5, y: centre.y + 2))
        chevron.lineWidth = 1.4
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        ink.setStroke()
        chevron.stroke()
        if showKeys { drawHint("R", in: rect, onClay: locked) }
    }

    // MARK: Converting

    /// A screen rectangle in this view's own space.
    private func viewRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX - screen.frame.minX,
               y: rect.minY - screen.frame.minY,
               width: rect.width,
               height: rect.height)
    }

    /// A point in screen space, from an event in this view.
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: local.x + screen.frame.minX,
                       y: local.y + screen.frame.minY)
    }

    // MARK: The gestures

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if readingState != nil {
            // The bar is the only thing with an answer here. A press on the
            // region would otherwise start a new rectangle under a result that
            // is still being decided about — and the rectangle drawn by a press
            // meant to dismiss something is the oldest way to lose work in this
            // window.
            _ = takeBarClick(at: local)
            return
        }
        if mode == .long {
            // The bar has a window of its own and that window is above this one,
            // so these presses are normally not ours. They are ours while the
            // pointer is over the bar, where ignoring the mouse would hand the
            // press to the page underneath instead.
            //
            // Logged, because the ways a press can end a long capture are the
            // whole question: a line here and a line from the bar's own window
            // say which one arrived, and only one of them arriving for ever is a
            // bug in the other.
            let geometry = bar()
            let onPill = geometry.done.contains(local)
            let onClose = geometry.close.contains(local)
            if onPill {
                diagLog("Capture long: took the press itself, on the pill")
            }
            if onClose {
                diagLog("Capture long: took the press itself, on the ✕")
            }
            // Deferred one turn: ending the capture tears both windows down, and
            // this view has to outlive the event it is dispatching.
            if onPill {
                DispatchQueue.main.async { [weak self] in self?.finishLong() }
            } else if onClose {
                DispatchQueue.main.async { [weak self] in self?.onCancel() }
            }
            return
        }
        if takeBarClick(at: local) {
            barPress = true
            return
        }
        let point = screenPoint(event)

        if let rect = selection {
            // Double-click inside takes it, the same way the editor's crop
            // frame is applied by double-clicking it. One rule for two frames:
            // the app already teaches "draw it, then double-click it" — and a
            // chosen window is a frame too, so it is taken whole rather than
            // cropped out of whatever happens to be in front of it.
            if event.clickCount == 2, viewRect(rect).contains(local) {
                // Deferred a turn, like every other ending here: taking the
                // picture closes this window, and a view cannot be torn down
                // from inside an event it is still dispatching.
                DispatchQueue.main.async { [weak self] in self?.confirm() }
                return
            }
            // A window is not a rectangle, so there is nothing to resize and
            // nothing to move: its frame is the window's. The handles are not
            // drawn either (see `draw`), which is the visible half of the same
            // fact.
            if frameIsResizable, let handle = handle(at: local, in: rect) {
                press = .resizing(handle, from: point, rect: rect)
                return
            }
            if frameIsResizable, viewRect(rect).contains(local) {
                press = .moving(from: point, rect: rect)
                return
            }
        }
        press = .drawing(from: point)
        dragged = false
        selection = nil
        chosenWindow = nil
        needsDisplay = true
    }

    /// Answers a press that landed on the bar, and reports whether it was the
    /// bar's to answer.
    ///
    /// Without this every press would start a rectangle — including the ones
    /// aimed at the button, which would leave a two-point selection behind a
    /// click meant to open a menu. A press outside an open panel closes it and is
    /// spent doing so, the way every popover on this system behaves: the click
    /// that dismisses a thing is not also a click on the thing underneath.
    private func takeBarClick(at local: NSPoint) -> Bool {
        let bar = bar()
        // A reading is a question with two answers. Anything else pressed while
        // it is up — the region, a shape, another mode — is not one of them, so
        // the bar answers and the rest of the screen is quiet.
        //
        // Deferred a turn, like the long capture's own branch: closing the
        // window from inside an event this view is dispatching pulls the view
        // out from under the dispatch.
        if readingState != nil {
            // Said with the geometry: "the copy button does nothing" is the same
            // report for a press that missed the pill and a press the pill
            // refused, and only one of those is worth fixing.
            diagLog("Capture text: bar press at \(Int(local.x)),\(Int(local.y))"
                + " — pill \(Int(bar.done.minX))…\(Int(bar.done.maxX))"
                + "×\(Int(bar.done.minY))…\(Int(bar.done.maxY)),"
                + " live \(pillLive), translating \(translating)")
            if bar.close.contains(local) {
                DispatchQueue.main.async { [weak self] in self?.onCancel() }
            } else if pillLive, bar.capsule.contains(local) {
                // The whole capsule, not only the pill. While a reading is up
                // the bar has exactly two answers — take the words, or leave —
                // so a press that lands on the bar and not on the ✕ is a press
                // asking for the words. The pill stays what is *drawn* as the
                // button; the target is deliberately larger than the ink,
                // because a 50-point pill that must be hit to the point is a
                // button that works most of the time — which is exactly how
                // this one was reported.
                DispatchQueue.main.async { [weak self] in self?.finishReading() }
            }
            return true
        }
        if panelOpen {
            for (option, rect) in bar.options where rect.contains(local) {
                aspect = option
                panelOpen = false
                needsDisplay = true
                return true
            }
            if bar.panel.contains(local) {
                return true          // the panel's own air, not a choice
            }
            panelOpen = false
            needsDisplay = true
            return true              // the press spent itself dismissing the panel
        }
        if bar.button.contains(local) {
            panelOpen = true
            needsDisplay = true
            return true
        }
        if bar.long.contains(local) {
            armLong()
            return true
        }
        if bar.read.contains(local) {
            armRead()
            return true
        }
        if bar.translate.contains(local) {
            armTranslate()
            return true
        }
        if bar.edit.contains(local) {
            // What Return would take, taken one step further: the picture lands
            // the way it always lands, and then opens in the editor. The target
            // is worked out before the turn is given up, because ending the
            // capture is what the turn buys and this view will not be here for
            // it.
            let chosen = target
            DispatchQueue.main.async { [weak self] in self?.onEdit(chosen) }
            return true
        }
        if againShown, bar.again.contains(local) {
            // The same area again. Nothing to arm and nothing to draw here: the
            // light comes on with the frame, in `restore`. Deferred a turn for
            // the same reason every other ending is — the press tears the
            // capture down, and this view has to outlive the event it is
            // dispatching.
            DispatchQueue.main.async { [weak self] in self?.onAgain() }
            return true
        }
        return bar.capsule.contains(local)
    }

    /// Asks for a long capture, from the button or from `L`.
    ///
    /// Written once because the two entries have to mean exactly the same
    /// thing: a key that quietly did something else from the button beside it
    /// would be a second definition of the mode.
    ///
    /// With no region yet this arms rather than refusing — the next drag becomes
    /// the region that keeps growing, which is the whole point of choosing the
    /// mode before drawing.
    private func armLong() {
        if let rect = selection {
            enterLong(rect)
        } else {
            longArmed = true
            // Three modes cannot all be waiting for the next drag: whichever
            // was asked for last is the one the person means.
            readArmed = false
            translateArmed = false
            needsDisplay = true
        }
    }

    /// Asks for the words in an area, from the button or from `W`.
    ///
    /// Written once, for the same reason `armLong` is: a key that quietly did
    /// something else from the button beside it would be a second definition of
    /// the mode.
    ///
    /// With no region this arms rather than refusing, the way 长图 does — the
    /// next drag becomes the area to read, which is the point of choosing the
    /// mode before drawing.
    private func armRead() {
        guard mode == .shot, reading == nil else { return }
        if let rect = selection {
            startReading(rect, purpose: .hang)
        } else {
            readArmed = true
            longArmed = false
            translateArmed = false
            needsDisplay = true
        }
    }

    /// Asks for the words in the area, in another language, from the button or
    /// from `T`.
    ///
    /// A door of its own beside `识别`, and not a switch on a finished reading,
    /// because the two asks end in different places: `识别` hands the words to
    /// the line, `译` hands them to the person and keeps nothing. A switch would
    /// mean every translation started as a capture, and would leave the answer
    /// on a bar with no way to say "that is what I wanted" except the same pill
    /// that would have hung a card.
    private func armTranslate() {
        guard mode == .shot, reading == nil else { return }
        if let rect = selection {
            startReading(rect, purpose: .translate)
        } else {
            translateArmed = true
            longArmed = false
            readArmed = false
            needsDisplay = true
        }
    }

    /// Starts reading a region, and takes the bar into the state that answers
    /// what was read.
    ///
    /// Cuts nothing itself: pictures are the controller's half, and the region is
    /// cut out of the backdrop it is holding. This asks, and then waits for
    /// `showReading(_:)`.
    private func startReading(_ rect: CGRect, purpose: ReadingPurpose) {
        guard mode == .shot, reading == nil else { return }
        readArmed = false
        longArmed = false
        translateArmed = false
        panelOpen = false
        selection = rect
        hovered = nil
        reading = .going
        // Which door this came in through is remembered here and nowhere else,
        // and it is what every later step asks instead of guessing: one answer,
        // set once, so a copy and a translation can never be interleaved.
        readingPurpose = purpose
        if purpose == .translate {
            translation = nil
            translating = false
            refusal = nil
            translateNoop = false
        }
        // The crosshair and the window highlight have nothing to say over a
        // result: the pointer is answering a question now, not choosing an area.
        // It also stops the watch drawing a cursor over a picture that is no
        // longer what is being looked at.
        endTracking()
        onReadArea(rect)
        needsDisplay = true
        diagLog("Capture text: reading \(Int(rect.width))×\(Int(rect.height)) pt"
            + (purpose == .translate ? ", to translate" : ""))
    }

    /// What the read had to say, or nil when it failed outright.
    ///
    /// An empty answer is a state of its own rather than a failed one: "looked
    /// at and holds no words" is the answer to the question, and a screen with
    /// no text on it is a perfectly ordinary thing to point at by mistake.
    func showReading(_ text: String?) {
        guard reading != nil else { return }
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        reading = trimmed.isEmpty ? .nothing : .found(trimmed)
        needsDisplay = true
        diagLog("Capture text: \(trimmed.isEmpty ? "nothing found" : "\(trimmed.count) character(s)")")
        // The translate door asks the engine by itself. Reading the area was a
        // step it needed, not a question it wanted answered: what was asked for
        // was the other language, and stopping here to ask for a press would be
        // asking the person to finish a sentence they already finished.
        if !trimmed.isEmpty, readingPurpose == .translate {
            askTranslation(trimmed)
        }
    }

    /// Ends the reading, in whichever language it is showing.
    ///
    /// Two doors, two endings, and the difference is the whole reason they are
    /// two doors: `识别` puts the words on the line to be kept, and `译` puts them
    /// on the screen to be read and then on the pasteboard — and keeps nothing.
    private func finishReading() {
        guard let state = readingState, case .found(let text) = state else { return }
        guard readingPurpose == .translate else {
            onFinishText(text)
            return
        }
        // Nothing to take away while the engine is still working: the question
        // is open, and Return during it must not throw the answer away.
        guard !translating else { return }
        onFinishTranslation(translationText ?? text)
    }

    /// Asks the engine for the words in the other language.
    ///
    /// Called by itself the moment the read comes back, never by a button of its
    /// own: choosing `译` and drawing the area was the whole decision, and asking
    /// for a second press afterwards would be two presses for one answer.
    private func askTranslation(_ text: String) {
        guard !translating else { return }
        translating = true
        refusal = nil
        translateNoop = false
        needsDisplay = true
        diagLog("Capture text: translating \(text.count) character(s)")
        onTranslate(text)
    }

    /// What the engine had to say, or nil when it could not.
    func showTranslation(_ text: String?) {
        guard translating else { return }
        translating = false
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Said on the bar rather than swallowed: an engine that answers
            // nothing is indistinguishable from one that was never asked.
            refusal = .failed
            needsDisplay = true
            diagLog("Capture text: no translation came back")
            return
        }
        // The same words back means they are already in the language asked
        // for — an English page on an English Mac. Switching to them would be
        // a button that visibly does nothing, so it says so instead.
        if case .found(let text)? = readingState, trimmed == text {
            translateNoop = true
            refusal = nil
            needsDisplay = true
            diagLog("Capture text: already in that language")
            return
        }
        translation = trimmed
        refusal = nil
        translateNoop = false
        needsDisplay = true
        diagLog("Capture text: translated, \(trimmed.count) character(s)")
    }

    /// Why there is no translation, said on the bar and nowhere else.
    ///
    /// One entry point for the three answers, so a new one cannot be added
    /// without choosing which sentence it gets — the state this replaces spent
    /// two rounds as a single unhelpful 无法翻译.
    func showTranslationRefused(_ reason: Refusal) {
        translating = false
        refusal = reason
        translateNoop = false
        needsDisplay = true
        diagLog("Capture text: refused — \(reason)")
    }

    /// The engine's way of saying these words are already in this language.
    ///
    /// Its own answer rather than a failure. The system's engine does not hand
    /// the words back when asked to translate them into the language they are
    /// already in — it throws `nothingToTranslate` — so the only way to tell
    /// "already is" from "could not" is to be told which one happened. Said on
    /// the bar because a button that visibly did nothing reads as a button that
    /// did not work.
    func showTranslationNoop() {
        translating = false
        translateNoop = true
        refusal = nil
        needsDisplay = true
        diagLog("Capture text: already in that language")
    }

    override func mouseDragged(with event: NSEvent) {
        let point = screenPoint(event)
        switch press {
        case .idle:
            return

        case .drawing(let start):
            if !dragged {
                guard hypot(point.x - start.x, point.y - start.y) > Self.dragSlop else { return }
                dragged = true
                // The window under the pointer stops being the answer the moment
                // a rectangle is being drawn — two highlights for one gesture is
                // one too many.
                hovered = nil
            }
            selection = rectangle(from: start, to: point)

        case .moving(let start, let rect):
            if !dragged {
                guard hypot(point.x - start.x, point.y - start.y) > Self.dragSlop else { return }
                dragged = true
                // Something is in the hand now, and the hand is closed.
                NSCursor.closedHand.set()
            }
            selection = Self.moved(rect, from: start, to: point, within: screen.frame)

        case .resizing(let handle, _, let rect):
            // No dead zone here: the pointer is already on an edge it has hold
            // of, and three points of nothing on a handle reads as a handle
            // that did not take.
            dragged = true
            selection = Self.resized(rect, by: handle, to: point,
                                     aspect: aspect, within: screen.frame)
        }
        needsDisplay = true
    }

    /// A drag's rectangle, in screen coordinates, with the locked shape applied.
    ///
    /// The pointer decides the longer side and the lock decides the other. The
    /// editor's crop frame lets the width alone decide, which is right for a
    /// frame being pulled out around a picture and wrong here: dragging down for
    /// a 9:16 strip would otherwise produce a frame one pixel wide and hundreds
    /// tall, and the shape would only appear if the hand also went sideways.
    ///
    /// Anchored at `start`, in whichever direction the hand went, and shrunk as
    /// a pair when it runs out of screen: clamping one side on its own would
    /// break the ratio at exactly the moment the selection reached an edge —
    /// which is where a locked shape is most likely to be dragged.
    ///
    /// Static and free of the view, so `CaptureSelfTest` can check the
    /// arithmetic against a made-up screen instead of against this one. Pure
    /// geometry that has never been tested is geometry that is wrong in the one
    /// case nobody dragged. `nonisolated` because it is arithmetic: the view is
    /// main-actor bound, numbers are not.
    nonisolated static func rectangle(from start: NSPoint, to point: NSPoint,
                                      aspect: CropAspect, within bounds: CGRect) -> CGRect {
        var width = abs(point.x - start.x)
        var height = abs(point.y - start.y)
        if let ratio = aspect.ratio, ratio > 0 {
            width = max(width, height * ratio)
            height = width / ratio
        }
        let rightwards = point.x >= start.x
        let upwards = point.y >= start.y
        let room = CGSize(
            width: rightwards ? bounds.maxX - start.x : start.x - bounds.minX,
            height: upwards ? bounds.maxY - start.y : start.y - bounds.minY)
        if width > room.width || height > room.height {
            let scale = min(room.width / max(width, 1), room.height / max(height, 1))
            width = max(0, width * scale)
            height = max(0, height * scale)
        }
        return CGRect(x: rightwards ? start.x : start.x - width,
                      y: upwards ? start.y : start.y - height,
                      width: width, height: height)
    }

    private func rectangle(from start: NSPoint, to point: NSPoint) -> CGRect {
        Self.rectangle(from: start, to: point, aspect: aspect, within: screen.frame)
    }

    /// Turns the rectangle already drawn to the newly chosen shape.
    ///
    /// Anchored at its bottom-left corner and driven by its width: the corner
    /// nearest the size badge stays put, so the badge does not jump across the
    /// screen while the shape is being chosen.
    private func reshapeSelection() {
        guard let rect = selection, rect.width > 0 else { return }
        guard let ratio = aspect.ratio, ratio > 0 else { return }
        let anchor = NSPoint(x: rect.minX, y: rect.minY)
        selection = rectangle(from: anchor,
                              to: NSPoint(x: anchor.x + rect.width,
                                          y: anchor.y + rect.width / ratio))
    }

    /// The release, which no longer takes the picture.
    ///
    /// Letting go is how a frame gets drawn, not how it gets decided. The first
    /// version finished here, which made the rectangle final at the exact
    /// moment it first existed — leaving no moment in which to fix it, and a
    /// rectangle always needs fixing: it is drawn by eye, at speed, while the
    /// hand is moving. The release now leaves the frame on screen with its
    /// handles out, and the picture is taken by Return, by double-clicking the
    /// frame, or not at all (Esc).
    ///
    /// A press that never moved chooses rather than takes: a click on a window
    /// makes it the answer, and a click on nothing gives the gesture back.
    /// Taking is Return, Enter or a double-click, and nothing else.
    override func mouseUp(with event: NSEvent) {
        let answered = press
        press = .idle
        let moved = dragged
        dragged = false
        if barPress {
            barPress = false
            refreshHover()
            return
        }
        guard case .drawing = answered, !moved else {
            // The hand has just let go of something, and the cursor still says
            // it is holding it: the watch only ticks when the pointer moves, and
            // the pointer is not going to move. Asked here rather than waited
            // for.
            refreshHover()
            // A drag that was asked for a growing region becomes one, now that
            // there is a region to grow. The same for a region to read: both
            // modes were chosen before the rectangle existed, and this is the
            // rectangle arriving.
            if longArmed, let rect = selection {
                enterLong(rect)
            } else if readArmed, let rect = selection {
                startReading(rect, purpose: .hang)
            } else if translateArmed, let rect = selection {
                startReading(rect, purpose: .translate)
            }
            return
        }
        // A click goes back to being a click: whatever was armed was armed for
        // a drag, and this was not one.
        longArmed = false
        readArmed = false
        translateArmed = false
        // A click chooses, and does not take (2026-11-03). Same rule as a drag:
        // the gesture says *what*, and Return or a second click says "now". A
        // click used to take the window under it at once, which was the only
        // place in this window where one press meant both — and it left the
        // bar's buttons with nothing to act on, since by the time you could
        // reach them the picture had already been taken.
        //
        // Asked again rather than trusted from `hovered`, because the press
        // itself is a fresh answer to "what is under the pointer".
        if let window = WindowPick.window(at: screenPoint(event), in: windows) {
            choose(window)
        } else {
            // A click on the desktop with nothing under it. Given back rather
            // than turned into a whole-screen grab: the answer to "I clicked
            // nothing" should not be "here is a picture of everything".
            onCancel()
        }
    }

    // MARK: Choosing, then taking

    /// What is chosen: the window, the frame, or the whole screen when nothing
    /// has been chosen at all.
    ///
    /// The last fallback is what makes Return useful from a cold start — the
    /// whole screen is the capture that needs no choice — and it is the same
    /// answer Space gives by filling the frame in, reached the other way round.
    var target: CaptureTarget {
        if let chosenWindow { return .window(chosenWindow) }
        if let selection { return .region(selection) }
        return .region(screen.frame)
    }

    /// Takes what is chosen, the way Return does.
    ///
    /// One meaning for Return, the keypad's Enter and a double-click, because
    /// they are one act. Private on purpose: the three entry points are the
    /// only callers, and a public `take` would be a fourth way to end a capture
    /// invented by whoever called it next.
    private func confirm() {
        switch target {
        case .window(let window): onPick(window)
        case .region(let rect): onFinish(rect)
        }
    }

    /// Chooses a window, without taking it.
    ///
    /// Its frame becomes the selection — one rectangle, one set of geometry, so
    /// the dim, the border and the size badge all come for free and cannot
    /// disagree with the picture that will be taken. What the numbers cannot
    /// carry is the identity, and that is `chosenWindow`: a window is rendered
    /// from its own surface, not cropped out of the backdrop, which is the
    /// difference between a covered window coming out whole and coming out
    /// covered.
    private func choose(_ window: PickableWindow) {
        chosenWindow = window
        selection = window.frame
        // The hover has done its job. Left lit it would draw a white outline
        // under the clay one, saying "about to be chosen" about something that
        // has been.
        setHovered(nil)
        needsDisplay = true
        diagLog("Capture: chose window \(window.id) of \(window.owner), "
            + "\(Int(window.frame.width))×\(Int(window.frame.height))")
    }

    /// Fills the frame with the whole screen.
    ///
    /// Space used to take the picture where it stood. It now means the same as
    /// a drag around everything — a choice, which Return then agrees with — and
    /// the frame is a real frame, so its edges can be pulled in afterwards.
    private func selectScreen() {
        chosenWindow = nil
        setHovered(nil)
        selection = screen.frame
        needsDisplay = true
        diagLog("Capture: chose the whole screen, "
            + "\(Int(screen.frame.width))×\(Int(screen.frame.height))")
    }

    // MARK: Growing downwards

    /// Turns the drawn region into one that keeps growing as the page scrolls.
    ///
    /// The window stops being a window in the two senses that matter here: it
    /// ignores the mouse, so the wheel reaches the app being scrolled instead of
    /// stopping at an invisible sheet of glass, and it turns transparent so that
    /// app can be *seen* scrolling. Nothing is posted into the other app — no
    /// `CGEvent`, no Accessibility permission — the person scrolls, and this
    /// watches.
    private func enterLong(_ rect: CGRect) {
        guard mode == .shot else { return }
        mode = .long
        longArmed = false
        readArmed = false
        translateArmed = false
        panelOpen = false
        selection = rect
        hovered = nil
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.ignoresMouseEvents = true
        window?.invalidateShadow()
        // The pointer watch has nothing left to say, and a cursor being set by
        // this app while another app is being scrolled is two apps fighting
        // over an arrow.
        endTracking()
        // The front — and with it the keyboard — goes to the app being scrolled
        // from here on, on purpose. The controller owns that half: it registers
        // the keys that have to answer anyway before letting go.
        onEnterLongMode()
        diagLog("Capture long: growing \(Int(rect.width))×\(Int(rect.height)) pt")

        // The first frame is cut from the frozen backdrop, not grabbed fresh: it
        // is the screen as it was when the overlay opened, which is the top of
        // the page by definition. A grab a moment later can already be one
        // scroll down — and the top of a long picture is the one part that
        // cannot be got back.
        if let seed = CaptureController.crop(backdrop, to: rect, on: screen) {
            stitcher.start(seed)
        }
        needsDisplay = true
        startSampling()
    }

    private func startSampling() {
        sampling?.invalidate()
        // Three samples a second. A wheel notch arrives every 50–100 ms and a
        // trackpad reports continuously, so anything slower starts missing the
        // overlap the stitch depends on.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampling = timer
    }

    private func sample() {
        // The bar's window says where the pointer is the moment it moves, and
        // that is what opens this window to presses. This is the backstop, and it
        // covers two cases at once: the pointer left without a word, and the
        // bar's window saying nothing at all — a window left accepting clicks
        // would refuse the wheel to the page for the rest of the capture, which
        // is the one thing long mode cannot afford.
        if mode == .long, let window {
            let pointer = NSEvent.mouseLocation
            let local = NSPoint(x: pointer.x - screen.frame.minX,
                                y: pointer.y - screen.frame.minY)
            let overBar = bar().capsule.contains(local)
            if window.ignoresMouseEvents == overBar {
                window.ignoresMouseEvents = !overBar
                // Only on the change, so this says when the fallback opened and
                // when it closed rather than that the timer is running. If the
                // bar's own window never reports a press, this line and the
                // press line in `mouseDown` are what say the fallback is the
                // path that works.
                diagLog("Capture long: pointer \(overBar ? "over" : "off") the bar "
                    + "— this window now \(overBar ? "takes" : "gives back") presses")
            }
        }
        guard mode == .long, let rect = selection, !busy else { return }
        busy = true
        let screen = self.screen
        Task {
            defer { busy = false }
            do {
                // The old exclusion of everything this app draws, kept for the
                // one grab that is taken with the dim on screen: without it
                // every frame would come back with the overlay painted over the
                // page, and the stitcher would happily line those up.
                let frame = try await ScreenGrab.areaImage(in: rect, on: screen,
                                                          excludingThisApp: true)
                guard mode == .long else { return }
                ingest(frame)
            } catch {
                stopSampling()
                longNote = error.localizedDescription
                needsDisplay = true
            }
        }
    }

    /// One more frame, measured against the last.
    private func ingest(_ frame: CGImage) {
        switch stitcher.append(frame) {
        case .advanced:
            longNote = nil
        case .still:
            // The wheel is at rest. Saying so every third of a second would be
            // a line that flickers, and there is nothing to fix.
            break
        case .lost(let why):
            longNote = why
        }
        needsDisplay = true
    }

    private func stopSampling() {
        sampling?.invalidate()
        sampling = nil
    }

    /// Ends the long capture and hands over the picture.
    ///
    /// Not private: while this app is not front, Return arrives as a Carbon hot
    /// key owned by the controller, which then calls this directly. Two ways in,
    /// one place that decides — the key event path and the hot key path must
    /// end the capture identically or the difference will be discovered later
    /// as "it behaves differently depending on how I stopped it".
    ///
    /// With nothing stitched on top of the first frame this is not a long
    /// picture at all — the person pressed Return without scrolling — so it is
    /// finished as an ordinary capture instead of refusing. A mode that answers
    /// "you did not use me" with an error is a mode that punishes the wrong
    /// person.
    func finishLong() {
        // Three ways in now — Return, the pill, and this window taking the press
        // itself — and two of them can answer the same press: the pill's window
        // and this one both stand where the pointer was. Ending a capture twice
        // would hand the same picture over twice, so the second caller is told
        // there is nothing left to end.
        guard mode == .long else { return }
        stopSampling()
        // Logged with the count because "完成 did nothing" and "完成 gave me an
        // ordinary picture" are the same press and different complaints, and
        // only this number tells them apart afterwards.
        let decision = Self.longDecision(frames: stitcher.count, hasRegion: selection != nil)
        diagLog("Capture long: Done with \(stitcher.count) frame(s) → \(decision)")
        switch decision {
        case .picture:
            guard let image = stitcher.image() else {
                onCancel()
                return
            }
            onFinishLong(image)
        case .ordinary:
            guard let rect = selection else { return onCancel() }
            onFinish(rect)
        case .nothing:
            onCancel()
        }
    }

    /// What ending a long capture does, given how many frames it has.
    ///
    /// A separate, answerable question rather than three lines inside
    /// `finishLong`, because the case worth doubting is the one with nothing
    /// stitched on top — the person pressed Done without scrolling, or scrolled
    /// the wrong way — and the one thing it must never do is take the pill away
    /// or refuse. It is finished as an ordinary picture of the region instead:
    /// a mode that answers "you did not use me" with an error punishes the
    /// person who is already confused about how it works.
    ///
    /// `.ordinary` rather than `.nothing` for a failed seed too — a region is a
    /// region whether or not the first frame could be cut from it.
    nonisolated static func longDecision(frames: Int, hasRegion: Bool) -> LongDecision {
        if frames > 1 { return .picture }
        return hasRegion ? .ordinary : .nothing
    }

    /// The three shapes a Done press can take.
    enum LongDecision: Equatable {
        /// Frames were stitched: hand over the long picture.
        case picture
        /// Nothing was stitched: hand over the region as an ordinary shot.
        case ordinary
        /// Not even a region to shoot.
        case nothing
    }

    /// What a press is doing, in one of three exclusive ways.
    private enum Press {
        case idle
        case drawing(from: NSPoint)
        case moving(from: NSPoint, rect: CGRect)
        /// The handle is kept because a resize has to know which two edges stay
        /// put, and which one follows the pointer.
        case resizing(Handle, from: NSPoint, rect: CGRect)
    }

    /// Which edge or corner of a drawn rectangle a press has hold of.
    ///
    /// Eight rather than the four corners: a rectangle rounded off against a
    /// window's edge is adjusted one side at a time far more often than it is
    /// re-drawn, and the corners of a 16:9 frame are still the corners of a
    /// shape the hand already got nearly right.
    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

        var touchesLeft: Bool { self == .topLeft || self == .bottomLeft || self == .left }
        var touchesRight: Bool { self == .topRight || self == .bottomRight || self == .right }
        var touchesTop: Bool { self == .topLeft || self == .topRight || self == .top }
        var touchesBottom: Bool { self == .bottomLeft || self == .bottomRight || self == .bottom }

        /// Where it sits on a rectangle, in the rectangle's own space.
        func point(in rect: CGRect) -> NSPoint {
            NSPoint(x: touchesLeft ? rect.minX : (touchesRight ? rect.maxX : rect.midX),
                    y: touchesBottom ? rect.minY : (touchesTop ? rect.maxY : rect.midY))
        }
    }

    /// How far from a handle a press still counts as being on it. Bigger than
    /// the dot: the dot is 6 points so it reads as a dot, the target is 9 so it
    /// can be hit without aiming.
    private static let grabRadius: CGFloat = 9

    /// The handle under a point, corners first.
    ///
    /// A corner overlaps the two edges that meet there, and the corner is both
    /// the more useful of the two and the harder one to hit; resolving the
    /// overlap the other way round would put a corner out of reach whenever the
    /// rectangle was small.
    private func handle(at local: NSPoint, in rect: CGRect) -> Handle? {
        let box = viewRect(rect)
        for handle in Handle.allCases {
            let point = handle.point(in: box)
            if hypot(local.x - point.x, local.y - point.y) <= Self.grabRadius { return handle }
        }
        return nil
    }

    /// The cursor a handle wears.
    ///
    /// macOS 15 grew the right cursors for this — a diagonal one for a corner,
    /// and it points inward or outward according to which way the frame can
    /// still grow. Before that there is no diagonal resize cursor at all, only
    /// the four straight ones, so the sides get the true one and the corners
    /// the nearest; a slightly wrong arrow beats no arrow on the one part of
    /// the frame that can be dragged two ways at once.
    private static func cursor(for handle: Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            case .top: position = .top
            case .bottom: position = .bottom
            case .left: position = .left
            case .right: position = .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return handle.touchesTop || handle.touchesBottom ? .resizeUpDown : .resizeLeftRight
    }

    /// A frame dragged by one of its handles.
    ///
    /// Two edges stay, the ones opposite the handle; the handle itself goes
    /// where the pointer goes. With a shape locked, the free axis cannot be
    /// free — but which way it should follow depends on what is being held:
    ///
    /// - A **corner** is a drag from the opposite corner, which is exactly the
    ///   geometry `rectangle(from:to:)` already does, so it is asked rather
    ///   than re-derived. The pointer decides the longer side there as well,
    ///   which is what makes a corner feel the same locked or unlocked.
    /// - A **side** has no second dimension to read from the pointer, so the
    ///   lock drives it — grown around the frame's own centre line, because
    ///   pulling one edge should scale the frame, not walk it off what it is
    ///   framing.
    ///
    /// Near the screen edge the whole frame stops rather than the ratio
    /// breaking: at the one moment there is no more room, a shape that is no
    /// longer the chosen shape is the worse of the two answers.
    nonisolated static func resized(_ rect: CGRect, by handle: Handle, to point: NSPoint,
                                    aspect: CropAspect, within bounds: CGRect) -> CGRect {
        /// Below this a frame is a line, and a line cannot be grabbed again.
        let floor: CGFloat = 8

        if let ratio = aspect.ratio, ratio > 0 {
            let corner = (handle.touchesLeft || handle.touchesRight)
                && (handle.touchesTop || handle.touchesBottom)
            if corner {
                let anchor = NSPoint(x: handle.touchesLeft ? rect.maxX : rect.minX,
                                     y: handle.touchesBottom ? rect.maxY : rect.minY)
                return rectangle(from: anchor, to: point, aspect: aspect, within: bounds)
            }
            if handle == .left || handle == .right {
                let width = max(floor, handle == .left ? rect.maxX - point.x : point.x - rect.minX)
                let room = 2 * min(rect.midY - bounds.minY, bounds.maxY - rect.midY)
                var height = width / ratio
                var kept = width
                if height > room {
                    height = max(floor, room)
                    kept = height * ratio
                }
                return CGRect(x: handle == .left ? rect.maxX - kept : rect.minX,
                              y: rect.midY - height / 2, width: kept, height: height)
            }
            let height = max(floor, handle == .bottom ? rect.maxY - point.y : point.y - rect.minY)
            let room = 2 * min(rect.midX - bounds.minX, bounds.maxX - rect.midX)
            var width = height * ratio
            var kept = height
            if width > room {
                width = max(floor, room)
                kept = width / ratio
            }
            return CGRect(x: rect.midX - width / 2,
                          y: handle == .bottom ? rect.maxY - kept : rect.minY,
                          width: width, height: kept)
        }

        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.touchesLeft { minX = min(point.x, maxX - floor) }
        if handle.touchesRight { maxX = max(point.x, minX + floor) }
        if handle.touchesBottom { minY = min(point.y, maxY - floor) }
        if handle.touchesTop { maxY = max(point.y, minY + floor) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A frame moved by dragging its inside.
    ///
    /// Displaced from where it started rather than nudged from where it is:
    /// a rectangle that is stopped by the edge of the screen would otherwise
    /// keep the distance it was denied, and jump free of the pointer's hand the
    /// moment it came back. And it rubs along the edge instead of leaving the
    /// screen, because a frame half off the screen is a frame whose handles
    /// cannot be grabbed back.
    nonisolated static func moved(_ rect: CGRect, from start: NSPoint,
                                  to point: NSPoint, within bounds: CGRect) -> CGRect {
        var out = rect.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        out.origin.x = min(max(bounds.minX, out.minX), bounds.maxX - out.width)
        out.origin.y = min(max(bounds.minY, out.minY), bounds.maxY - out.height)
        return out
    }

    /// Closes the ratio panel if it is open, and says whether it did.
    ///
    /// The controller's Escape hot key calls this too: the panel has to eat the
    /// key that would close it whether the key arrived as an event here or as a
    /// Carbon hot key from an app that is not front. One rule, one place.
    @discardableResult
    func dismissPanel() -> Bool {
        guard panelOpen else { return false }
        panelOpen = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Logged because "the keys stopped working" has two very different
        // causes — a key that arrives and is ignored, and a key that never
        // arrives — and nothing else can tell them apart after the fact.
        diagLog("Capture: key \(event.keyCode) "
            + "(\(mode == .long ? "long" : reading == nil ? "shot" : "reading"))")
        switch event.keyCode {
        case 53:                    // Esc — closes the panel before the window
            if !dismissPanel() { onCancel() }
        case 49:                    // Space
            // Means "all of it" only while there is still a choice to make.
            // Mid long-capture it would throw away everything stitched so far,
            // and pressing it by accident while scrolling is likely; with a
            // reading waiting it would be answering the question with a
            // different one.
            //
            // It fills the frame in rather than taking the picture (2026-11-03):
            // Space chooses, Return agrees. The frame being real means its edges
            // can then be pulled in, which a grab of the whole display never
            // allowed.
            guard mode == .shot, reading == nil else { return }
            selectScreen()
        case 36, 76:                // Return, keypad Enter
            if reading != nil {
                // Agreeing with what was read. The one key that means "yes" in
                // this window, and here it does not take a picture.
                finishReading()
                return
            }
            if mode == .long {
                finishLong()
            } else {
                // Whatever is chosen — the window, the drawn frame, or the
                // whole screen when neither exists.
                confirm()
            }
        case 15:                    // R — round the fixed shapes and back to free
            // The shape of a growing region is decided before it starts
            // growing; half-way down a page there is nothing to reshape, and a
            // reading has already been cut.
            guard mode == .shot, reading == nil else { return }
            let all = CropAspect.allCases
            let index = all.firstIndex(of: aspect).map { $0 + 1 } ?? 0
            aspect = all[index % all.count]
        case 37:                    // L — the region keeps growing downwards
            // The same act as the button beside the ratio one. A bare key rather
            // than a hot key, and the difference matters: choosing a mode only
            // means something while the choice is still open, whereas a global
            // `L` would take that letter from every app for the length of the
            // capture. Return and Esc are registered globally because they are
            // the way *out*; an entrance does not need that.
            guard mode == .shot, reading == nil else { return }
            armLong()
        case 13:                    // W — the words in the area, not a picture of it
            // The same rule as `L`, and the same reason for not being global.
            // `W` and not `T`: the letter names the gesture the app already
            // teaches — select — and `T` would sit next to `R` and `L` reading
            // as "text tool", which is the editor's word for something else.
            guard mode == .shot, reading == nil else { return }
            armRead()
        case 17:                    // T — the same words in another language
            // An entrance like `L` and `W`, and a bare key for the same reason:
            // a global `T` would take that letter from every app for the length
            // of the capture, and choosing a mode only means anything while the
            // choice is still open.
            guard mode == .shot, reading == nil else { return }
            armTranslate()
        case 0:                     // A — the last frame, back where it was
            // The one key on this bar that ends the capture and takes nothing:
            // it puts the frame back and waits for Return like any other frame.
            // (`E`, below, is the other key that ends one — but it takes the
            // picture first, which is the difference between "again" and
            // "edit".)
            //
            // Silent when there is nothing to put back — the state in which the
            // button is not drawn either. A key that beeped about a button
            // nobody can see would be worse than the button being absent.
            //
            // `A` for again, and the letter itself carries no other meaning
            // here: it is a bare key during the capture, not a global hot key,
            // so nothing is taken from the app underneath.
            guard mode == .shot, reading == nil, againShown else { return }
            // Deferred a turn for the reason the button is: the press tears the
            // capture down, and this view has to outlive the event it is
            // dispatching. The chip lights when the frame lands, not here —
            // `restore` is the only place that knows a frame came back.
            DispatchQueue.main.async { [weak self] in self?.onAgain() }
        case 14:                    // E — take it, then open it in the editor
            // Return with one more step: the picture lands exactly the way it
            // always lands, and then opens. The target is worked out before the
            // turn is given up, because ending the capture is what the turn buys
            // and this view will not be here for it — the same reason the button
            // does it this way.
            guard mode == .shot, reading == nil else { return }
            let chosen = target
            DispatchQueue.main.async { [weak self] in self?.onEdit(chosen) }
        default:
            super.keyDown(with: event)
        }
    }

    /// Right click gives the gesture back, the way it does in the system's own
    /// capture. Nothing else in this window means anything on a right click.
    override func rightMouseDown(with event: NSEvent) {
        onCancel()
    }
}
