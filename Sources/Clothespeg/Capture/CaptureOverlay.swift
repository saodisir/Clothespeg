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

/// The words on a result card arrive from the top down, one line at a time.
///
/// Arithmetic over elapsed time rather than a per-line animation object: a
/// window full of timers is a window nobody can debug. Keeping the rule here
/// also means the harness can ask "is row 0 ahead of row 3 at 50 ms" without
/// starting an animation on a view that has no window, and a flat staircase
/// (all lines at once) fails a plain comparison.
enum ResultReveal {
    static let stagger: TimeInterval = 0.045
    static let fade: TimeInterval = 0.18

    static func alpha(row: Int, elapsed: TimeInterval) -> CGFloat {
        CGFloat(min(1, max(0, (elapsed - Double(row) * stagger) / fade)))
    }

    static func duration(rows: Int) -> TimeInterval {
        Double(max(0, rows - 1)) * stagger + fade + 0.03
    }
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
    /// An eyedropper. The same symbol the editor's colour picker wears, so
    /// the two doors are recognisably the same reading.
    static let colour = "eyedropper"
    static let ratio = "aspectratio"
    /// A scroll: the one picture that says "longer than the screen" without a
    /// word. The arrow it replaced said "down", which is half the story and
    /// reads as a download at 14 points.
    static let long = "scroll"
    /// A bubble with a character in it: the words inside the area come back as
    /// words, which is a different promise from "this box is a box".
    ///
    /// Its two predecessors were both frames (`text.viewfinder`, `viewfinder`)
    /// and a frame says nothing the selection's own border has not already
    /// said — at 14 points it reads as "scan", which is a barcode. The letter
    /// inside the bubble is the thing that is being read.
    static let read = "character.bubble"
    /// A globe of the eastern hemisphere: the one symbol in the row with no words
    /// in it, which is the whole reason it is here.
    ///
    /// The book before it was the better idea and the worse answer.
    /// `character.book.closed` draws whatever character the **system language**
    /// uses — an `A` on an English Mac, 文 on this one — and AppKit offers no way
    /// to ask for a particular variant: `NSImage.SymbolConfiguration(locale:)`
    /// does not exist, so a toolbar drawn with it is a different icon for every
    /// user. A symbol whose ink changes with the language of the person looking
    /// at it cannot be judged at 14 points, because it was judged at another
    /// size, in another language.
    ///
    /// `translate` (two overlapping bubbles) was the first answer, and its rear
    /// bubble ends in the bottom right corner — exactly where the key goes: the
    /// `T` read as a smudge. `character.bubble` followed it and had to be given
    /// up when the reading button took that one over. Continents rather than the
    /// plain `globe` because at 14 points a wireframe ball is a circle with
    /// lines in it, and a place is what this button is about.
    static let translate = "globe.asia.australia"
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
    /// The second exit of an in-place translation: hang the picture itself.
    static let hangImage = "photo"
    /// The second exit of a card translation: the words **and** their
    /// translation, together, as text.
    ///
    /// Two panels rather than one, because that is the difference from the check
    /// beside it: the check hands over the answer, this hands over the answer
    /// and the question. It was asked for in exactly those terms (2026-11-13):
    /// 「增加一个按钮，就变成双语一起复制，这样对照着去看？只复制文字，不是复制图片」.
    ///
    /// `doc.on.doc` was the first answer and was wrong about its own meaning: it
    /// is macOS's *copy* glyph, offset sheets and all, and beside a ✕ and a ✓ it
    /// promised a duplicate rather than a second text. Reported the same evening:
    /// 「这个按钮其实有点'复制'的意思…至少目前这个图标不是特别合适」. What the
    /// button hands over is two blocks of text one above the other — exactly what
    /// the result card is — so the glyph is that card: a rectangle divided in
    /// two.
    ///
    /// Three candidates were rendered in the real bar before this one was taken
    /// (30 × 26 chip, 2× pixels, measured off the stills):
    ///
    /// - `bubble.left.and.text.bubble.right` says "two texts" best of anything in
    ///   the system, and was given up on weight: 19.5 × 15.5 pt against this
    ///   one's 16 × 12.5. The folded bar's quietest control would have been its
    ///   heaviest glyph, and two speech bubbles also read as Messages.
    /// - `text.rectangle` is one block with one line in it: "text", never "two".
    /// - `text.alignleft` is a paragraph of rules and nothing else.
    ///
    /// The key badge is not part of this argument: `bar.second` is drawn with
    /// `key: nil`, so the bottom-right corner is free whatever glyph is here —
    /// unlike the five chips that carry a letter.
    static let bothTexts = "rectangle.split.1x2"
    /// The chip beside `译`, in its two states: where the words come back.
    ///
    /// Symbols now, not the hand-drawn faces these started as. A person looking
    /// at the bar asked what the two drawings had to do with translation
    /// (2026-11-13), and the answer had to be "nothing" — two stacked lines is
    /// a paragraph, a framed line is a minus sign.
    ///
    /// Then the second face was reported as not clear either (2026-11-13). A
    /// coherent pair was tried and given up on: a panel split down the middle
    /// beside two panels one over the other is exactly the *beside / on top*
    /// distinction, and `rectangle.split.2x1` is what `自由` already wears
    /// (`aspectratio` is an inner rectangle with a divider) — two neighbouring
    /// chips that look alike is the ambiguity this was meant to remove, moved
    /// rather than fixed. So `translate` stays on the card: it is the one glyph
    /// in the system that means translation on its own, the `译` chip next door
    /// wears a globe rather than it, and the in-place face below says the other
    /// half of the pair in shapes.
    static let presentationCard = "translate"
    /// A second sheet laid on the first, which is what the in-place answer is:
    /// the words are not moved, a layer is put over them. `character.textbox`
    /// lost on two counts — it draws the character the **system language** uses
    /// (an `A` here, 字 there), and on a Chinese Mac it drew a 字 in a box
    /// beside the reading chip's 字. Two chips saying 字 is one too many.
    static let presentationInPlace = "rectangle.on.rectangle"
    /// The way out, beside the way on.
    ///
    /// A symbol since 2026-11-13, and it was drawn by hand before that for a
    /// reason that turned out to be about the **character** `✕` and not about
    /// this glyph: "a ✕ is not in every font, and the one that has it sits low
    /// in a 22-point box" is true of a text glyph and false of the system
    /// symbol, which is available from macOS 11 and is centred by construction.
    /// The hand-drawn cross also had its own size — a 3.6-point arm, 8.6 points
    /// of ink — which was the smallest of the three marks in the row and the
    /// half of 「这个图标的大小也不一致啊」 that nobody could name.
    static let close = "xmark"
    /// Every symbol this bar can draw, so the self-test asks each one by name:
    /// a symbol renamed between two macOS releases draws as a blank box, and
    /// nothing else in a build would say so.
    static let all = [ratio, long, read, colour, translate, again, edit, close,
                      presentationCard, presentationInPlace, hangImage, bothTexts]
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
    /// `M`, or the chip that says where the answer lands, was pressed before
    /// there was a region. The next region is translated the moment it exists.
    ///
    /// It used to say *which* chip asked, so the light could come on under the
    /// right one — and then both chips stopped being doors. The globe became a
    /// select box on 2026-11-13 (「其实它没有按钮的作用，只是一个选择框」), so
    /// only one chip can still be waiting for anything, and one flag says it.
    private var translateArmed = false
    /// Which door the region came in through.
    ///
    /// The pixels and the Vision request are the same either way; what differs
    /// is what happens to the words afterwards — one hangs them on the line,
    /// the other puts them back on the screen and keeps nothing.
    private enum ReadingPurpose { case hang, translate, inPlace }
    private var readingPurpose: ReadingPurpose = .hang
    /// Harness only: the words a reading would show. There is no screen for a
    /// harness to read, and the bar is exactly what needs looking at.
    var previewReading: String?
    /// Harness only: the translation of those words, as if one had come back.
    var previewTranslation: String?

    /// Harness only: the sheet of words, having come in through `识别`.
    /// The pill is the same check whichever door the words came through.
    func showReadingForTesting(_ text: String?) {
        previewReading = text
        readingPurpose = .hang
        needsDisplay = true
    }

    /// Harness only: the same sheet, having come in through `译` — the words in
    /// the other language, and the same check at the end of the bar.
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
    /// How many areas the engine had nothing for, when it had nothing for some.
    ///
    /// A picture that came back half in its original language used to look
    /// exactly like a picture that had been translated badly, and there was no
    /// way to tell which had happened — reported 2026-11-13 as 「翻译不全」.
    /// Now the bar says how many places stayed as they were, and the answer is
    /// "the engine had nothing for them" rather than a guess.
    private var translateNote: String?
    /// What the bar is saying for a moment about something that changed with
    /// nothing else on screen changing with it.
    ///
    /// One case so far: `T` walking the shortlist (2026-11-13). The language chip
    /// carries no word — asked for in 2026-11-03, 「这个按钮不需要显示中文或英文等
    /// 语言类型」 — so while the key was only opening a menu that was fine, and the
    /// moment the key changes the answer instead, the change has to be said
    /// somewhere. The line is the place that already says the state.
    private var saidNote: String?
    private var saidTimer: Timer?
    /// The controller asks the engine and comes back through
    /// `showTranslation(_:)`; nil means it could not.
    var onTranslate: (String) -> Void = { _ in }
    /// The translation, on its way out. Nothing hangs on the line: what was
    /// asked for was to read this area in another language, and the reading is
    /// over when the screen goes away.
    var onFinishTranslation: (String) -> Void = { _ in }

    /// The in-place door. Its reading is a picture, not a sheet of words, so
    /// it has its own way in and one extra way out; the check still hands the
    /// words over as text.
    var onReadInPlace: (CGRect) -> Void = { _ in }
    var onFinishInPlaceImage: (CGImage) -> Void = { _ in }
    private var inPlaceImage: CGImage?
    /// The same area *before* the words were replaced, and where each replaced
    /// block sits in it.
    ///
    /// The finished picture is all a static answer needs; an answer that arrives
    /// a block at a time needs both — the original to lay underneath, the boxes
    /// to know in what order and how far each one has got. Boxes are Vision's
    /// own (normalised, bottom-left) and are kept in *reading* order: top first.
    private var inPlaceBase: CGImage?
    private var inPlaceBoxes: [CGRect] = []
    /// Counts in-place answers, so each arrival gets its own reveal key.
    private var answerSerial = 0
    /// How the words come back once the area is agreed: on a card beside the
    /// original, or painted over the words themselves.
    ///
    /// A setting rather than a mode, and the distinction is the whole reason it
    /// has a chip of its own: a mode changes what the next drag means, and this
    /// changes nothing about the drag — only where the answer lands. The card is
    /// the default, so the old path stays exactly as long as it was.
    ///
    /// Per capture in how it is shown, remembered across captures in what it is:
    /// the same question every time — *where does the answer go* — and answering
    /// it again on every capture is answering a question the person has already
    /// answered. Asked for in as many words (2026-11-13): 「我选了哪个，下一次
    /// 就默认是这个」. It stays a setting rather than a mode for the older
    /// reason, and it writes through on the click that chooses it, so the next
    /// window opens on the same answer with nothing to keep in step.
    enum Presentation: String, Equatable {
        case card, inPlace
        /// What the menu calls it. Two words rather than a sentence: the rows
        /// are read at a glance, and the long version of each lives in the
        /// chip's tool tip.
        var name: String {
            switch self {
            case .card: return L("Side by side")
            case .inPlace: return L("In place")
            }
        }
        /// In the order the menu lists them: the default first, because the
        /// first row is where the eye starts and where the tick usually is.
        static let all: [Presentation] = [.card, .inPlace]

        static let storageKey = "translationPresentation"

        /// Where the answer is kept, behind a seam.
        ///
        /// A pair of closures rather than `UserDefaults` at each call site, for
        /// one measured reason: the harness has to show that a choice survives
        /// the window, and it must not do that by writing into the settings of
        /// whoever ran it. The version that did — set the key, click, set it
        /// back — left `inPlace` behind, because a test process ends in
        /// `exit(0)` and a preference written at the last moment is not always
        /// flushed. It then poisoned a different check that assumed the default.
        private static var readSetting: () -> String? = {
            UserDefaults.standard.string(forKey: Presentation.storageKey)
        }
        private static var writeSetting: (String?) -> Void = { value in
            if let value {
                UserDefaults.standard.set(value, forKey: Presentation.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Presentation.storageKey)
            }
        }

        /// Points the seam at somewhere harmless. Harness only.
        static func useStorageForTesting(read: @escaping () -> String?,
                                        write: @escaping (String?) -> Void) {
            readSetting = read
            writeSetting = write
        }

        static func restoreRealStorage() {
            readSetting = { UserDefaults.standard.string(forKey: Presentation.storageKey) }
            writeSetting = { value in
                if let value {
                    UserDefaults.standard.set(value, forKey: Presentation.storageKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Presentation.storageKey)
                }
            }
        }

        /// What the last capture used, or the card when nothing was chosen yet.
        /// The card is the older path and the safer default: a first capture
        /// that silently repaints the page is a bigger surprise than one that
        /// puts the words beside it.
        static var remembered: Presentation {
            guard let raw = readSetting(), let way = Presentation(rawValue: raw) else {
                return .card
            }
            return way
        }

        static func remember(_ way: Presentation) { writeSetting(way.rawValue) }
    }
    var presentation: Presentation = Presentation.remembered
    var presentationForTesting: String { presentation == .card ? "card" : "inPlace" }

    /// What the region is showing, in the harness or for real.
    private var readingState: Reading? { reading ?? previewReading.map { .found($0) } }

    /// A colour reading is a state of its own, not a fourth `armed` flag.
    /// Those three are for a drag: `mouseUp` clears all of them on a plain
    /// click, and a colour is chosen by exactly such a click. Aiming holds no
    /// rectangle at all — the input is one pixel — so a region that happens
    /// to be on screen has nothing to say about it.
    private var colourAiming = false
    private var colourResult: (point: NSPoint, colour: NSColor)?
    /// Where the pointer is while aiming, in view points.
    private var colourHover: NSPoint?
    /// The card drawn for the colour, in view points. Handed to the harness
    /// rather than recomputed there: two copies of the placement would be two
    /// answers to "is the answer where the pixel was".
    private var colourCard: NSRect?
    /// The swatch inside that card. Handed out rather than recomputed in the
    /// harness: whether its rim can be seen is a question about the drawn
    /// rectangle, not about a second copy of the layout arithmetic.
    private var colourSwatch: NSRect?
    var colourCardForTesting: NSRect? { colourCard }
    var colourSwatchForTesting: NSRect? { colourSwatch }
    /// The value in the collapsed bar's middle slot, for the harness. The
    /// sentence beside it already has `lineForTesting`.
    var middleForTesting: String { bar().middleText }
    var colourHexForTesting: String? {
        colourResult.map { ColourSampler.hex($0.colour) }
    }
    var colourAimingForTesting: Bool { colourAiming }
    var hasColourResultForTesting: Bool { colourResult != nil }

    /// What the last aiming repaint asked AppKit to redraw. Two small
    /// rectangles here is the trail bug coming back, so the self test reads it.
    private var lastDirtyForTesting: [NSRect] = []
    var dirtyForTesting: [NSRect] { lastDirtyForTesting }
    func moveColourForTesting(_ point: NSPoint) { moveColourHover(to: point) }

    /// Either door that ends with an answer on a card and a check on the bar.
    private var hasResult: Bool { readingState != nil || colourResult != nil }

    /// The colour value, on its way out. Nothing is written and nothing is
    /// named: the controller puts it on the pasteboard and hangs one text card.
    var onFinishColour: (String) -> Void = { _ in }

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

    /// The words as they were read, before a translation joined them.
    ///
    /// `shownText` is what gets copied — a translation, once there is one. This
    /// one is what the card sets *above* the translation, because a translation
    /// on its own cannot be checked by anyone who does not read both languages.
    private var wordsText: String? {
        if case .found(let text)? = readingState { return text }
        return nil
    }

    /// Where the result card was put, in view coordinates.
    ///
    /// Written by `drawResultCard` because the placement is arithmetic over the
    /// text it is about to draw, and read back by two people: the harness, which
    /// has to sample inside it, and `mouseDown`, which must not treat a press on
    /// the words as the start of a new frame.
    private(set) var resultCard: NSRect = .zero

    // MARK: The answer arriving

    /// When the words on the card last changed. The reveal restarts on a change
    /// of *content*, not on a change of state: a paragraph and its translation
    /// are two answers, while a repaint caused by the pointer or the appearance
    /// is not one. A loading line is not an answer either, so it arrives whole.
    private var resultRevealStart: TimeInterval?
    private var resultRevealKey: String?
    private var resultRevealRows = 0
    private var revealTimer: Timer?

    private func noteReveal(key: String, rows: Int, animated: Bool) {
        resultRevealRows = rows
        // A view without a window is the harness or an off-screen preview.
        // Neither should start a clock: they take one still picture, and a
        // half-faded one would turn every pixel assertion into a coin toss.
        guard animated, window != nil, resultRevealKey != key else { return }
        resultRevealKey = key
        resultRevealStart = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - (self.resultRevealStart ?? now)
                if elapsed < ResultReveal.duration(rows: self.resultRevealRows) {
                    self.setNeedsDisplay(self.resultCard.insetBy(dx: -2, dy: -2))
                } else {
                    // One last whole repaint at alpha 1, then the clock stops.
                    self.stopReveal()
                    self.needsDisplay = true
                }
            }
        }
        stopReveal()
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func revealAlpha(_ row: Int) -> CGFloat {
        guard window != nil, let start = resultRevealStart else { return 1 }
        return ResultReveal.alpha(
            row: row, elapsed: ProcessInfo.processInfo.systemUptime - start)
    }

    /// Whether this frame is one of the fading ones. Outside the animation the
    /// card is drawn once, exactly as it always was: clipping a block into
    /// strips would leave hairline seams at the strip edges on a static card,
    /// and the pixel checks would start measuring the seams instead of the ink.
    private var isRevealing: Bool {
        guard window != nil, let start = resultRevealStart else { return false }
        return ProcessInfo.processInfo.systemUptime - start
            < ResultReveal.duration(rows: resultRevealRows)
    }

    private func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    /// The translated picture, arriving the way the card's lines do.
    ///
    /// The words in place used to be one flip: the whole area went from English
    /// to Chinese between two frames, and the answer read as a still rather than
    /// as something that had just been worked out. Asked for in as many words
    /// (2026-11-13): 「我们翻译的时候是从上到下面入的，现在原位置翻译的话，最好
    /// 也是这个效果」.
    ///
    /// So the same clock as `ResultReveal`, one row per block instead of one row
    /// per line: the original sits underneath, and each translated block is
    /// clipped into place as its turn comes. Blocks are the unit because they
    /// are what the engine answered — a line-by-line wipe would cut through a
    /// paragraph in the middle of a sentence, and a growing rectangle would cut
    /// through the middle of a glyph.
    ///
    /// Two paths, on purpose. Outside the animation the finished picture is
    /// drawn once, exactly as before: clipping a static picture into boxes
    /// leaves hairline seams at the box edges, and the pixel checks would start
    /// measuring the seams instead of the words.
    private func drawInPlace(_ image: CGImage, in region: NSRect) {
        let whole = NSImage(cgImage: image,
                            size: NSSize(width: image.width, height: image.height))
        guard isRevealing, let base = inPlaceBase, !inPlaceBoxes.isEmpty else {
            whole.draw(in: region)
            return
        }
        NSImage(cgImage: base, size: NSSize(width: base.width, height: base.height))
            .draw(in: region)
        // Blocks that have finished go in one clipped pass; the one or two still
        // fading get their own. A dozen separate full-picture draws at 30 frames
        // a second is a stutter, and a full-screen capture is a dozen blocks.
        let settled = NSBezierPath()
        var fading: [(rect: NSRect, alpha: CGFloat)] = []
        for (row, box) in inPlaceBoxes.enumerated() {
            let alpha = revealAlpha(row)
            guard alpha > 0 else { continue }
            // Half a point of slack: the clip edge and the picture's own edge
            // land on different sub-pixels otherwise, and the seam shows as a
            // one-pixel line down a paragraph.
            let rect = imageBox(box, in: region).insetBy(dx: -0.5, dy: -0.5)
            if alpha >= 0.999 {
                settled.appendRect(rect)
            } else {
                fading.append((rect, alpha))
            }
        }
        if !settled.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            settled.addClip()
            whole.draw(in: region, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        for step in fading {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: step.rect).addClip()
            whole.draw(in: region, from: .zero, operation: .sourceOver, fraction: step.alpha)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A Vision box in the region it was cut from.
    ///
    /// The overlay's own coordinates are the screen's — bottom-left, no flip —
    /// which is Vision's convention too, so this is a scale and an offset and
    /// nothing else. (`TranslatedImage` does flip, because the context it draws
    /// into was flipped on purpose.)
    private func imageBox(_ box: CGRect, in region: NSRect) -> NSRect {
        NSRect(x: region.minX + box.minX * region.width,
               y: region.minY + box.minY * region.height,
               width: box.width * region.width,
               height: box.height * region.height)
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
    private var collapsed: Bool {
        mode == .long || readingState != nil || colourResult != nil || previewLong != nil
    }

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
        revealTimer?.invalidate()
        saidTimer?.invalidate()
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
        // The capture is over, or has become a long one: a clock that keeps
        // repainting a card nobody is looking at is the same mistake the
        // sampling clock used to make.
        stopReveal()
        // And the note's: two seconds later it would repaint a bar that is no
        // longer on screen.
        saidTimer?.invalidate()
        saidTimer = nil
    }

    private func tick() {
        let pointer = NSEvent.mouseLocation
        if let last = lastPointer, hypot(pointer.x - last.x, pointer.y - last.y) < 0.5 {
            return
        }
        lastPointer = pointer
        if colourAiming {
            let local = NSPoint(x: pointer.x - screen.frame.minX,
                                y: pointer.y - screen.frame.minY)
            moveColourHover(to: local)
            // The bar still has a ✕ to press, and the arrow is what says so.
            if bar().capsule.contains(local) {
                NSCursor.arrow.set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }
        // Held down, the pointer is doing something to the frame; a window
        // lighting up under it would be a second answer to the same gesture.
        guard !pressing else { return }
        refreshHover()
    }

    /// Pointer movement while aiming. Pulled out of `tick()` so the harness can
    /// move the loupe without a live mouse and still walk the same repaint.
    ///
    /// The whole screen is the dirty rectangle. The first version repainted
    /// only the two loupe rectangles and left a ring drawn on the pointer
    /// behind at every step — a trail of white dots. That ring has since moved
    /// to the result card, but the full repaint stays: this state is one flat
    /// dim over the whole screen plus a moving disc, and a partial repaint is
    /// one more thing to keep in step if anything is ever added to it.
    /// `ColourLoupe.rect` is for the editor, where the loupe really is the
    /// only thing that moves.
    private func moveColourHover(to local: NSPoint) {
        colourHover = local
        lastDirtyForTesting = [bounds]
        needsDisplay = true
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

        // A colour reading has no rectangle to explain. The dimming stays flat
        // all the way across, the loupe or the card is the only thing on it,
        // and the check on the bar is the only way out.
        if colourAiming || colourResult != nil {
            if colourAiming { drawColourAim(in: context) } else { drawColourCard() }
            drawBar()
            return
        }

        if let rect = highlightedRect {
            let local = viewRect(rect)
            if readingState != nil {
                // The answer is the only thing left lit. Lifting the chosen
                // rectangle back out of the dimming would leave a bright frame
                // around a small card — the bigger the frame, the more of the
                // screen insists on being looked at — and drawing its edge would
                // give the card a border it can never cover. Once the words are
                // on the card the frame has no job left: the dimming stays flat,
                // the card is the whole result, and the size of the frame stops
                // being something the picture has to explain.
                drawResultCard(local)
            } else {
                backdropImage.draw(in: local, from: local, operation: .copy, fraction: 1)
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

    /// A ✕ on the bar's own wash: leaving without a picture.
    ///
    /// The box is a chip, not a disc. It was a disc for two years and that is
    /// what made the row look like two families of control: next to a chip the
    /// same ink and the same wash, the one round shape in a row of squares read
    /// as something else than the way out (2026-11-13). Same radius as every
    /// other pressable thing — see `chipRadius` — and, since the same evening,
    /// the same 30 × 26 box: 「距离大小、宽度、高度，理论上都应该是一样的」.
    ///
    /// The mark is the system's `xmark` now, not four stroked segments. It was
    /// drawn for a reason that was about the character `✕` — "not in every font,
    /// and the ones that have it sit low" — and a symbol is neither of those
    /// things. What the drawn version did keep for itself was a fourth size: a
    /// 3.6-point arm is 8.6 points of ink, in a row where the chips are 12 and
    /// the tick is 10.25. That is the other half of 「这个图标的大小也不一致
    /// 啊」, and it goes with the rest of them — see `markPointSize`.
    private func drawClose(_ rect: NSRect, lit: Bool) {
        let plate = NSBezierPath(roundedRect: rect,
                                 xRadius: Self.chipRadius, yRadius: Self.chipRadius)
        // The bar's ink rather than white, and the chips' own ten percent
        // rather than a wash of its own: on a light bar a white plate is not a
        // plate, it is nothing at all, and two greys one percent apart are the
        // kind of difference that reads as a mistake without being nameable.
        CaptureInk.ink(effectiveAppearance)
            .withAlphaComponent(lit ? 0.18 : 0.10).setFill()
        plate.fill()
        drawMark(CaptureSymbol.close, at: NSPoint(x: rect.midX, y: rect.midY),
                 ink: CaptureInk.ink(effectiveAppearance)
                    .withAlphaComponent(lit ? 0.95 : 0.7))
    }

    /// What was read, on a card laid over the frame it came from.
    ///
    /// Inside the frame was the first answer, and it failed for one reason: a
    /// frame's width and height are whatever the hand happened to make them, so
    /// the type had no fixed width to wrap into and no guaranteed height to sit
    /// in. A frame drawn round one line of small type is 14–22 points tall —
    /// shorter than a line of 12-point type, and short enough that `insetBy`
    /// turns the text box into `NSRect.null`, after which not one glyph is
    /// drawn; a frame drawn round a paragraph is forty points wide, so every
    /// line comes out as `…`. Neither is a number to tune: the *container* was
    /// making a typographic decision it knows nothing about (reported twice,
    /// 2026-11-03: 不显示 twice, then 省略号). So the card is its own surface
    /// with its own width — 340 to 560 points, whatever the frame is — and
    /// that has not changed.
    ///
    /// What changed on 2026-11-04 is where that surface goes. It used to be
    /// placed outside the frame and never on it, because the frame was the thing
    /// the words were checked against. The card now carries the original above
    /// the translation, so the check happens on the card itself; putting it
    /// anywhere else only sends the eye to two places. On the frame first,
    /// centred on it. The four margins stay as a fallback for a frame so close
    /// to a screen edge that the card would have to slide away from it, and a
    /// frame that is the whole screen still tucks the card into its corner.
    /// Longer text makes the card taller and the type wraps; nothing is cut
    /// mid-sentence. The one case that still has to stop — more words than the
    /// screen can hold — says so in a sentence rather than in an ellipsis.
    ///
    /// A translation is shown *with* the words it came from rather than instead
    /// of them. Replacing them was a rule the old container forced ("twice the
    /// words will not fit in the frame"); this one has room, and the question a
    /// translation asks — what did it actually say — is only answerable with the
    /// original still in sight. Both are on the card at once, with no gesture
    /// that switches between them.
    private func drawResultCard(_ region: NSRect) {
        guard let state = readingState else { return }
        // An in-place translation has no card: the picture itself is the
        // answer, sitting exactly where the words were read from.
        if let image = inPlaceImage {
            resultCard = region
            drawInPlace(image, in: region)
            return
        }
        let ink = CaptureInk.ink(effectiveAppearance)

        // What the card says: one block, or two when a translation came back.
        // Each block carries its own line height, because the original is set
        // smaller than the translation on purpose — that difference is what says
        // which is which without inventing a label to translate.
        typealias Block = (text: String, attributes: [NSAttributedString.Key: Any], line: CGFloat)
        var blocks: [Block] = []
        if translating {
            blocks = [(L("Translating…"), Self.cardText(ink, size: 13, alpha: 0.93), 19)]
        } else {
            switch state {
            case .going:
                blocks = [(L("Reading…"), Self.cardText(ink, size: 13, alpha: 0.93), 19)]
            case .nothing:
                blocks = [(L("No text found"), Self.cardText(ink, size: 13, alpha: 0.93), 19)]
            case .found:
                let words = wordsText ?? ""
                if let translation = translationText {
                    blocks.append((words, Self.cardText(ink, size: 12, alpha: 0.5), 17))
                    blocks.append((translation, Self.cardText(ink, size: 14, alpha: 0.95), 19))
                } else {
                    blocks.append((words, Self.cardText(ink, size: 13, alpha: 0.93), 19))
                }
            }
        }

        let padX: CGFloat = 16
        let padY: CGFloat = 14
        let between: CGFloat = 11
        let noteLine: CGFloat = 16
        let inset: CGFloat = 12
        let gap: CGFloat = 10

        // Width is the card's own, not the frame's — this is the whole point.
        let inside = bounds.insetBy(dx: inset, dy: inset)
        let available = max(bounds.width - inset * 2, 240)
        let widest = min(560, available)

        // What each block needs, and what it gets: a block that runs past the
        // bottom of the screen is cut to whole lines and the rest is replaced by
        // one sentence, because half a line of type is a worse answer than a
        // clear "there is more".
        //
        // A function of the width, because the width is not settled until the
        // placement is: narrower type is taller type, so "does the card fit
        // beside the frame" can only be asked of the card that width produces.
        func measure(_ width: CGFloat) -> (heights: [CGFloat], height: CGFloat, cut: Bool) {
            let inner = width - padX * 2
            let limit = max(160, bounds.height * 0.82) - padY * 2 - noteLine
            var heights: [CGFloat] = []
            var budget = limit
            var cut = false
            for (index, block) in blocks.enumerated() {
                let rect = (block.text as NSString).boundingRect(
                    with: NSSize(width: inner, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], attributes: block.attributes)
                let need = max(ceil(rect.height), block.line)
                let separator: CGFloat = index == 0 ? 0 : between * 2 + 1
                guard !cut else { heights.append(0); continue }
                if separator + need <= budget {
                    heights.append(need)
                    budget -= separator + need
                } else {
                    let leftover = max(0, budget - separator)
                    heights.append(max(0, (leftover / block.line).rounded(.down) * block.line))
                    budget = 0
                    cut = true
                }
            }
            let content = heights.enumerated().reduce(CGFloat.zero) { total, pair in
                total + pair.element + (pair.offset == 0 ? 0 : between * 2 + 1)
            }
            return (heights, padY * 2 + content + (cut ? noteLine : 0), cut)
        }

        // Centred on the frame rather than sharing its left edge. Sharing an
        // edge only reads as alignment while the card is about the frame's
        // width; with a frame 900 points wide and a card 560, one edge lines up
        // and the other 340 points say nothing, which is the "既不居中也不对齐"
        // of 2026-11-03. Centring is true at every width. Near a screen edge the
        // clamp does the only thing left, and the card hugs the screen's inset
        // instead of hanging over it.
        func alignedX(_ width: CGFloat) -> CGFloat {
            let centred = region.midX - width / 2
            return min(max(centred, inside.minX), max(inside.minX, inside.maxX - width))
        }

        // On the frame first, then the four margins as a fallback. A place
        // counts only when the whole card lands on the screen. "On the frame"
        // means the card still covers the frame's centre after the screen-edge
        // clamp; near an edge the clamp can slide it far enough away that the
        // answer would sit somewhere else, and then an honest margin is better
        // than a card pretending to be in place. A frame that is the whole
        // screen keeps its old corner placement instead.
        func place(_ width: CGFloat, _ height: CGFloat) -> NSRect? {
            let x = alignedX(width)
            let centre = NSPoint(x: region.midX, y: region.midY)
            let wholeScreen = region.width >= inside.width && region.height >= inside.height
            if !wholeScreen {
                let y = min(max(region.midY - height / 2, inside.minY),
                            max(inside.minY, inside.maxY - height))
                let over = NSRect(x: x, y: y, width: width, height: height)
                if over.contains(centre) { return over }
            }
            let below = NSRect(x: x, y: region.minY - gap - height, width: width, height: height)
            if below.minY >= inside.minY { return below }
            let above = NSRect(x: x, y: region.maxY + gap, width: width, height: height)
            if above.maxY <= inside.maxY { return above }
            let y = min(max(region.midY - height / 2, inside.minY),
                        max(inside.minY, inside.maxY - height))
            let right = NSRect(x: region.maxX + gap, y: y, width: width, height: height)
            if right.maxX <= inside.maxX { return right }
            let left = NSRect(x: region.minX - gap - width, y: y, width: width, height: height)
            if left.minX >= inside.minX { return left }
            return nil
        }

        // Full width first. The on-frame place takes it in nearly every case;
        // when it cannot (a frame at a screen edge, or one that is the whole
        // screen) the card tries again narrower: a tall narrow card in the margin
        // still says where the words are, where the wide one would have to be
        // tucked into a corner (2026-11-03: a 685×680 frame on a 1737×1124
        // screen left 521 and 507 points either side — not enough for 560, plenty
        // for 340, and the wide card ended up glued to the bottom edge across
        // the frame's border).
        var width = min(max(region.width, 340), widest)
        var measured = measure(width)
        var placed = place(width, measured.height)
        if placed == nil, width > 340 {
            // How wide the widest margin could ever be — not 340 on principle.
            // A margin that holds 480 points should get 480: the card is the
            // words of the picture next to it, and a 340 card in a 480 margin
            // reads as a card that gave up.
            let margins = max(inside.maxX - (region.maxX + gap), region.minX - gap - inside.minX)
            width = max(340, min(width - 1, min(widest, margins)))
            measured = measure(width)
            placed = place(width, measured.height)
        }
        let card: NSRect
        if let placed {
            card = placed
        } else {
            // Nowhere at all, which means the frame is nearly the whole screen.
            // Tucked into the frame's own corner — sharing an edge with the
            // thing it is about and standing off it by the same 12 points the
            // screen gets — rather than glued to the bottom of the display
            // while sharing the frame's left edge, which was the one position
            // that read as an accident.
            let x = min(max(region.minX + inset, inside.minX),
                        max(inside.minX, inside.maxX - width))
            var y = region.minY + inset
            if y + measured.height > inside.maxY {
                y = max(inside.minY, region.maxY - inset - measured.height)
            }
            card = NSRect(x: x, y: y, width: width, height: measured.height)
        }
        let inner = width - padX * 2
        resultCard = card

        // The answer arrives from the top down. Only real words do this:
        // "Reading…" and "Translating…" are states, not answers, and fading
        // them in would make a loading line look like a result.
        let animated: Bool
        if translating {
            animated = false
        } else {
            switch state {
            case .found: animated = true
            case .going, .nothing: animated = false
            }
        }
        let key = blocks.map { $0.text }.joined(separator: "\u{1}")
        let rows = blocks.enumerated().reduce(0) { total, pair in
            let height = measured.heights[pair.offset]
            guard height > 0 else { return total }
            return total + max(1, Int(ceil(height / pair.element.line)))
        }
        noteReveal(key: key, rows: rows, animated: animated)
        // One answer for the whole frame: asking the clock again on every line
        // could draw half a card striped and half of it whole.
        let animating = isRevealing
        let ctx = NSGraphicsContext.current?.cgContext

        let surface = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
        CaptureInk.panel(effectiveAppearance).setFill()
        surface.fill()
        // One hairline, for the same reason the frame has one: a light card on a
        // white page is a card with no edge.
        ink.withAlphaComponent(0.14).setStroke()
        surface.lineWidth = 1
        surface.stroke()

        var y = card.maxY - padY
        var row = 0
        for (index, block) in blocks.enumerated() where measured.heights[index] > 0 {
            if index > 0 {
                y -= between
                ink.withAlphaComponent(0.14).setFill()
                NSRect(x: card.minX + padX, y: y, width: inner, height: 1).fill()
                y -= between + 1
            }
            let box = NSRect(x: card.minX + padX, y: y - measured.heights[index],
                             width: inner, height: measured.heights[index])
            let strips = max(1, Int(ceil(measured.heights[index] / block.line)))
            if animating, let ctx {
                // One strip per line, top first. The block is drawn whole into
                // each strip, with the clip and the global alpha doing the work:
                // the text is never re-typeset, so a line break cannot move
                // while its line is fading in.
                for strip in 0..<strips {
                    let slice = NSRect(x: box.minX,
                                       y: box.maxY - CGFloat(strip + 1) * block.line,
                                       width: box.width, height: block.line)
                        .intersection(box)
                    let alpha = revealAlpha(row)
                    row += 1
                    guard !slice.isEmpty, alpha > 0 else { continue }
                    ctx.saveGState()
                    ctx.clip(to: slice)
                    ctx.setAlpha(alpha)
                    (block.text as NSString).draw(with: box,
                                                  options: [.usesLineFragmentOrigin],
                                                  attributes: block.attributes)
                    ctx.restoreGState()
                }
            } else {
                (block.text as NSString).draw(with: box, options: [.usesLineFragmentOrigin],
                                              attributes: block.attributes)
                row += strips
            }
            y -= measured.heights[index]
        }
        if measured.cut {
            (L("More text — all of it is in the clipboard") as NSString)
                .draw(with: NSRect(x: card.minX + padX, y: y - noteLine, width: inner, height: noteLine),
                      options: [.usesLineFragmentOrigin],
                      attributes: Self.cardText(ink, size: 11, alpha: 0.45))
        }
    }

    /// The body type on the result card.
    private static func cardText(_ ink: NSColor, size: CGFloat,
                                 alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1
        return [.font: NSFont.systemFont(ofSize: size),
                .foregroundColor: ink.withAlphaComponent(alpha),
                .paragraphStyle: style]
    }

    /// A point in view space to the same point in the frozen backdrop's
    /// pixels. The view is in screen points, the backdrop at backing scale,
    /// and both count y from the bottom — the same arithmetic `crop` uses,
    /// and the same one `ColourSampler` expects.
    private func colourImagePoint(_ viewPoint: NSPoint) -> CGPoint {
        let scale = CGFloat(backdrop.width) / max(bounds.width, 1)
        return CGPoint(x: viewPoint.x * scale, y: viewPoint.y * scale)
    }

    private func colourNeighbourhood(at viewPoint: NSPoint) -> ColourSampler.Neighbourhood? {
        ColourSampler.neighbourhood(in: backdrop,
                                    around: colourImagePoint(viewPoint), radius: 5)
    }

    /// While aiming: only the shared loupe. The system crosshair already marks
    /// the exact pixel, and the ring that used to sit under the pointer was a
    /// second cursor nobody asked for. That ring belongs to the answer: it
    /// comes back on the card's tether once a pixel has been taken, where it
    /// says "this pixel" instead of "here I am".
    private func drawColourAim(in ctx: CGContext) {
        guard colourAiming, let hover = colourHover, bounds.contains(hover),
              let near = colourNeighbourhood(at: hover) else { return }
        ColourLoupe.draw(in: ctx, neighbourhood: near,
                         centre: ColourLoupe.centre(for: hover, in: bounds))
    }

    /// After a click: one card with a swatch and the value, tethered to the
    /// pixel it came from. Point-sized, not picture-pixel-sized — the editor's
    /// tag is drawn into the image's own coordinates, this one is drawn on
    /// the overlay in screen points.
    private func drawColourCard() {
        guard let result = colourResult else { return }
        let hex = ColourSampler.hex(result.colour)
        let ink = CaptureInk.ink(effectiveAppearance)
        let text = NSAttributedString(string: hex, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: ink,
        ])
        // Sized from what it carries, with a floor. The old 168 × 56 card with
        // a 32 pt swatch and 15 pt digits was the largest thing on a screen
        // whose only job was to hand over seven characters. Everything here is
        // in points: the editor's tag is drawn in the image's own pixel
        // coordinates and must not be copied into this view.
        let padding: CGFloat = 10
        let side: CGFloat = 24
        let gap: CGFloat = 10
        let size = NSSize(width: max(124, padding * 2 + side + gap + ceil(text.size().width)),
                          height: 44)
        let interior = bounds.insetBy(dx: 12, dy: 12)
        let wanted = NSPoint(x: result.point.x + 18, y: result.point.y + 18)
        let x = min(max(wanted.x, interior.minX),
                    max(interior.minX, interior.maxX - size.width))
        let y = min(max(wanted.y, interior.minY),
                    max(interior.minY, interior.maxY - size.height))
        let card = NSRect(origin: NSPoint(x: x, y: y), size: size)
        colourCard = card

        // A pale line under a dark one, so the tether survives on any picture.
        let leader = NSBezierPath()
        leader.move(to: NSPoint(x: card.minX + 8, y: card.minY + 8))
        leader.line(to: result.point)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        leader.lineWidth = 3
        leader.stroke()
        NSColor.black.withAlphaComponent(0.75).setStroke()
        leader.lineWidth = 1.2
        leader.stroke()
        let ring = NSRect(x: result.point.x - 5, y: result.point.y - 5,
                          width: 10, height: 10)
        let pale = NSBezierPath(ovalIn: ring)
        NSColor.white.setStroke()
        pale.lineWidth = 2
        pale.stroke()
        let dark = NSBezierPath(ovalIn: ring.insetBy(dx: 1, dy: 1))
        NSColor.black.withAlphaComponent(0.8).setStroke()
        dark.lineWidth = 1
        dark.stroke()

        let surface = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8)
        CaptureInk.panel(effectiveAppearance).setFill()
        surface.fill()
        ink.withAlphaComponent(0.14).setStroke()
        surface.lineWidth = 1
        surface.stroke()

        let swatch = NSRect(x: card.minX + padding, y: card.midY - side / 2,
                            width: side, height: side)
        let swatchPath = NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4)
        (result.colour.usingColorSpace(.sRGB) ?? result.colour).setFill()
        swatchPath.fill()
        colourSwatch = swatch
        // Two strokes: a dark one outside, a pale one inside. A `#F8F8F8`
        // swatch on the light card and a near-black one on the dark card each
        // disappear into their own surface with a single stroke, and the pair
        // gives one of them an edge in either appearance. The white-only rim
        // that was here was invisible against the white panel — the whole
        // reason this card got a border.
        NSColor.black.withAlphaComponent(0.55).setStroke()
        swatchPath.lineWidth = 2
        swatchPath.stroke()
        let inner = NSBezierPath(roundedRect: swatch.insetBy(dx: 1.25, dy: 1.25),
                                 xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        inner.lineWidth = 1
        inner.stroke()

        let textX = swatch.maxX + gap
        let room = card.maxX - padding - textX
        text.draw(at: NSPoint(x: textX + max(0, (room - text.size().width) / 2),
                              y: card.midY - text.size().height / 2))
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
        /// The chip that carries a menu: `译`, and the way to change what it
        /// answers in without going to Settings.
        ///
        /// It is not a square and it is not a word either. The first draft made
        /// it a 30-point symbol like the four beside it, and then there was no
        /// way to reach the shortlist except Settings. The second draft put the
        /// language on it, and that made the row 105 points wider to say
        /// something that does not change — rejected the same evening by the
        /// person using it: 「只要选中之后一般不会再变，所以这个按钮不需要显示
        /// 中文或英文等语言类型。保留一个图标就可以。」
        ///
        /// So: the 30 points a chip has, plus 16 that are only the chevron. The
        /// icon translates, the chevron opens the menu, and which language is in
        /// force is said in the menu, in clay, where it is being looked for.
        var language = NSRect.zero
        /// The chevron end of that chip, which opens the menu instead of
        /// translating. Narrower than the body on purpose: the thing a person
        /// wants most of the time is the press that does not open anything.
        var languageMenu = NSRect.zero
        /// The rows of that menu, in the order they are drawn: language code
        /// and where it sits. A code rather than a name, because a name is what
        /// the code is for.
        var languageRows: [(String, NSRect)] = []
        /// The second button: the one that turns the region into something that
        /// keeps growing. It is a button and not a key because "this area will
        /// keep growing" is a kind of capture, not a place — no gesture says it.
        var long = NSRect.zero
        /// The third button: read the words out of the area instead of taking a
        /// picture of it. A button for the same reason 长图 is one — "this area
        /// is a thing to be read" is a kind of capture, and no gesture says it.
        var read = NSRect.zero
        /// The fourth button: read one pixel's colour instead of a picture of
        /// the area. The only button here whose answer needs no rectangle.
        var colour = NSRect.zero
        /// The chip beside `译` that says *how* the words come back.
        ///
        /// A second wide chip, and deliberately not a switch on `译`: the two
        /// things that used to be crammed into one press are a language and a
        /// place, and they are asked at different moments. This one is a
        /// setting — its face shows which way is in force, its chevron opens
        /// the two rows, and `译` is still the only button that runs anything.
        var presentation = NSRect.zero
        /// The chevron end of that chip, which opens its menu.
        var presentationMenu = NSRect.zero
        /// The two rows of that menu, in the order they are drawn.
        var presentationRows: [(Presentation, NSRect)] = []
        /// A second exit for that reading, to the left of the ✕. Drawn only when
        /// there is something extra to hand over — a picture in the in-place
        /// case, both texts in the card's — so the ✕ and the check keep the
        /// places they have always had.
        var second = NSRect.zero
        /// The middle of the bar while a long capture runs, where the two
        /// buttons were: one number, and the pill that ends the capture.
        var middle = NSRect.zero
        var middleText = ""
        /// The pill that ends a long capture. It is the only pressable thing
        /// while one runs, and the only way out that does not need a keyboard —
        /// the Return that ends it is a key borrowed from the page, and a
        /// borrowed key should not be the only way out.
        var done = NSRect.zero
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
        /// The checkmark at the far end of the row: take the picture.
        ///
        /// The same act as Return and a double-click, but pressable — asked for
        /// by the person using it (2026-11-03): 「有人不想双击，就想点击一个按钮，
        /// 明确确认这个步骤执行完了」. It stands where the word `esc` used to,
        /// which is the point: that word was a legend and nothing else, drawn
        /// and never hit-tested, so the last 27 points of a bar full of buttons
        /// were the only place that could not be pressed — while the one act the
        /// bar exists for had no button at all. A key legend is not worth the
        /// end of a toolbar; the way out moved into this button's tool tip.
        var confirm = NSRect.zero
        var panel = NSRect.zero
        var options: [(CropAspect, NSRect)] = []
    }

    private static let barHeight: CGFloat = 34
    private static let barPadding: CGFloat = 13
    private static let barGap: CGFloat = 10
    /// One corner for every pressable thing in this bar.
    ///
    /// Chips, the check, the ✕ and the rows of every menu wear it. It was
    /// mixed until 2026-11-13 — the chips were rounded squares, the ✕ was a
    /// disc — and the mix was reported as exactly that: 「叉子和勾，包括你选的
    /// 图标，有圆的有方的…应该统一一个形状的背景底」. A disc cannot be the one
    /// rule here anyway: the ratio chip carries a word and `译` is 46 points
    /// wide, and the only shape that covers a 30-point square, a 46-point chip
    /// and a 22-point exit is a rounded rectangle. So one radius, and the exit
    /// keeps its corner instead of losing it.
    ///
    /// The panels those menus sit in keep their 10: a panel is a sheet of
    /// paper, not a button, and a panel drawn with a button's corner would read
    /// as one enormous chip.
    private static let chipRadius: CGFloat = 7
    private static let lineFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    private static let buttonFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The buttons are chips now, and the numbers are the editor's own: 30 × 26
    /// with four points between them, the same box `ToolChip` wears. Two bars in
    /// one app that differ by a point read as two different apps.
    private static let chipWidth: CGFloat = 30
    private static let chipHeight: CGFloat = 26
    private static let chipGap: CGFloat = 4
    /// The one size every mark in this bar is drawn at.
    ///
    /// There were three of these numbers until 2026-11-13 — 14 for the icon row,
    /// 13 for the two chips that carry a chevron, 12 for the tick — plus a fourth
    /// that was not a number at all but a hand-drawn cross with a 3.6-point arm.
    /// The row read as four sizes because it was four sizes: 「这个图标的大小也
    /// 不一致啊」. Measured ink at 4× off the real bar, in points tall:
    /// `rectangle.split.1x2` 12.00, `xmark` 8.60, `checkmark` 10.25.
    ///
    /// Thirteen is where they meet. At one point size the symbols are already
    /// optically balanced by the system, which is Apple's job and not this bar's:
    /// measured at 13, `rectangle.split.1x2` is 15.00 × 12.00, `aspectratio`
    /// 15.00 × 12.00, `globe.asia.australia` 13.00 × 13.00 and `xmark`
    /// 10.50 × 10.50 — the cross is smaller in its box on purpose, because a
    /// diagonal reads bigger than the box it occupies.
    ///
    /// The tick is the one mark that is not the bar's weight: on clay a regular
    /// tick at this size is a hair, so it stays semibold (11.50 × 11.25).
    private static let markPointSize: CGFloat = 13
    /// The chevron's own strip at the right end of the language chip.
    ///
    /// Sixteen rather than the ratio chip's twenty, because there is no word
    /// beside it to keep clear of: the whole chip is 46 points wide, and a
    /// strip any narrower than this cannot be hit without aiming.
    private static let languageMenuWidth: CGFloat = 16
    /// The key, in the corner, at the size of a footnote to a footnote — copied
    /// from `ToolChip.drawHint` for the same reason: it is a remark about the
    /// button, not a second label on it.
    private static let hintFont = NSFont.systemFont(ofSize: 6.5, weight: .semibold)

    /// Which menu is showing under the bar, if any.
    ///
    /// One value rather than two flags, because two flags is a state in which
    /// both are true, and two panels cannot both be under a bar that is 34
    /// points tall. Mutual exclusion is a property of the type here, not a rule
    /// somebody has to remember in five places: opening one closes the other by
    /// construction.
    enum ShowingPanel {
        case none, ratio, language, presentation
    }

    /// Set by a chip that carries a chevron, cleared by a choice or by any
    /// press outside the panel.
    var panel: ShowingPanel = .none

    /// Whether anything is showing, for the places that only care about that.
    var panelOpen: Bool { panel != .none }

    /// The language a plain press of `译` translates into.
    ///
    /// Read when this overlay is built rather than on every frame: a capture is
    /// a modal moment, so the shortlist cannot change underneath it, and
    /// `bar()` is called by every hover, by every hit test and by the drawing.
    var translationLanguage = TranslationTargets.current

    /// The shortlist as it was when this capture opened.
    ///
    /// Read once, for the reason `translationLanguage` is: `bar()` runs on every
    /// hover and every hit test, and the capsule's width is pinned from
    /// `measuredLines`, which needs every note `T` can say — a read per frame to
    /// answer a question that cannot change mid-capture is a read too many.
    /// `T` walks this list, so what it can walk and what was measured are the
    /// same list by construction.
    private var languageShortlist = TranslationTargets.chosen

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
    /// What is happening, **and into which language**.
    ///
    /// The name is the part that can be wrong. The chip does not show the
    /// language — taken off on purpose in 2026-11-03, because it costs a word
    /// and the answer rarely changes — so a target that is not the one the
    /// person thinks is in force is invisible until the words come back in the
    /// wrong language. Reported exactly that way on 2026-11-13: 「我为什么翻译成
    /// 英文，它翻译成的是繁体」. This slot already says 「翻译中…」; naming the
    /// language costs nothing extra and makes the mistake visible while it is
    /// still happening, rather than after it lands.
    private var lineTranslating: String {
        guard let name = TranslationCatalogue.named(TranslationTargets.current)?.name else {
            return L("Translating…")
        }
        return String(format: L("Translating into %@…"), name)
    }
    /// The same, with the language named — the answer to "into what" is the
    /// whole point of the button, and the chip does not carry it. Reported
    /// 2026-11-13: 「我为什么翻译成英文，它翻译成的是繁体」, which was unanswerable
    /// from the screen because nothing said which language had been asked for.
    private var lineTranslated: String {
        guard let name = TranslationCatalogue.named(TranslationTargets.current)?.name else {
            return L("The words, in the other language")
        }
        return String(format: L("The words, in %@"), name)
    }
    private var lineTranslateFailed: String { L("Those words could not be translated") }
    private var lineTranslateUnsure: String { L("Cannot tell which language these words are in") }
    private var lineTranslateUnsupported: String {
        L("This Mac cannot translate between those two languages")
    }
    private var lineTranslateNoop: String { L("Those words are already in this language") }
    /// The colour answer, in the same two slots the words use: a sentence on
    /// the line, the value in the middle. The bar was empty between its ✕ and
    /// ✓ after the old wordy Done pill went away, which read as a control with
    /// nothing to control.
    private var lineColour: String { L("The colour at that pixel") }

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
         lineTranslateArmed, lineColour,
         lineGrowing, lineReading, lineTranslating, lineTranslated, lineTranslateFailed,
         lineTranslateNoop, lineTranslateUnsure, lineTranslateUnsupported,
         longNote ?? "", previewNote ?? "", translateNote ?? "",
         // Every note `T` can say. The names differ in length (「日本語」 against
         // 「繁體中文」), so the widest one the shortlist can produce has to be
         // measured while none of them is showing — the width is pinned, and a
         // note that arrived and widened the capsule would slide the ✓ away from
         // the hand going for it.
         ] + LongStitcher.notes + languageShortlist.map { languageNote($0) }
    }

    /// Where everything in the bar sits, in this view's own coordinates.
    ///
    /// Computed on demand rather than cached in the draw: a hit test and the
    /// picture it is clicking on have to be the same geometry, and two copies
    /// of it are two copies that can disagree.
    private func bar() -> Bar {
        var out = Bar()
        let settled = selection != nil || previewSelection != nil
        if let note = longNote ?? previewNote ?? saidNote {
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
        } else if let translateNote {
            // Before the ordinary reading line, and only while a reading is up:
            // it is a sentence about the answer on the picture, not a mode.
            out.lineText = translateNote
        } else if readingState != nil {
            out.lineText = translationText == nil ? lineReading : lineTranslated
        } else if colourResult != nil {
            // The answer is on the card; the bar says what it is and repeats
            // the value, in the same two slots a reading uses for its sentence
            // and character count. An empty stretch between ✕ and ✓ reads as a
            // control with nothing to control.
            out.lineText = lineColour
        } else if colourAiming {
            // Still pointing: no sentence yet. An instruction here was tried
            // and rejected; the crosshair and the loupe are enough.
            out.lineText = ""
        } else if growing {
            out.lineText = lineGrowing
        } else if readArmed {
            out.lineText = lineReadArmed
        } else if translateArmed {
            // The key arrived before the area did. With an area in hand there is
            // no armed state to describe — the press translates at once, and the
            // bar goes straight to 翻译中….
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
        // One chip carries a value and is therefore not a square: a symbol says
        // "this is a shape", the word says *which*, the chevron says it opens a
        // menu, and the key sits in the corner like every other chip's. Pinned
        // to the widest title, so a chip that resizes as the shape changes does
        // not move the four beside it.
        out.buttonText = aspect.title
        let valueWidth = (CropAspect.allCases
            .map { textWidth($0.title, Self.buttonFont) }.max() ?? 40)
        let buttonWidth = 8 + 13 + 5 + valueWidth + 3 + 9 + 8
        // The language chip is not pinned to anything, because it has no word on
        // it: a 30-point icon and a 16-point chevron, always. The value lives in
        // the menu, where the current one is clay. A chip that spelled the
        // language out was built first and rejected by the person using it, on
        // the grounds that the answer does not change and the width did — it
        // made the row 105 points wider for a fact nobody needs at the moment of
        // pressing.
        let languageChipWidth = Self.chipWidth + Self.languageMenuWidth
        // The second wide chip, and the same arithmetic: 30 points of face,
        // 16 of chevron. It is beside `译` because what the two answer is one
        // question asked twice — *which* language, and *where* the answer
        // goes — and a chip on the far side of the row would be a setting
        // about translation living away from the translation.
        let presentationChipWidth = Self.chipWidth + Self.languageMenuWidth
        // Every other chip is the same box, so one number each is all the row
        // needs — and the far end is a chip too now. The letter legend that used
        // to spell `esc` there is gone with the last word it carried: the keys
        // live in their corners, and the one that was left over was the one
        // that could not be pressed.
        out.middleText = middleLabel
        let confirmWidth = Self.chipWidth
        let chipCount = 4 + (againShown ? 1 : 0)

        // The two groups, measured the same way they are laid out below rather
        // than as a count times a width: a formula that counts is a formula
        // that has to be re-derived every time the row changes, and this row
        // has now changed three times.
        let valuesWidth = buttonWidth + Self.chipGap + languageChipWidth
            + Self.chipGap + presentationChipWidth
        let iconsWidth = CGFloat(chipCount) * Self.chipWidth
            + CGFloat(max(0, chipCount - 1)) * Self.chipGap
        let width = Self.barPadding * 2 + lineWidth + Self.barGap + 1 + Self.barGap
            + valuesWidth + Self.barGap + iconsWidth + Self.barGap + confirmWidth
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
        // The row is in two groups, and the spacing says so: four points inside
        // a group, ten across the seam. The first group is the three chips that
        // carry a value or a menu and are therefore asking a question; the
        // second is the four that are only a symbol and an answer. Read as one
        // undifferentiated run of seven, a person has to know which kind each
        // one is before pressing it — and the two kinds respond to different
        // things: one opens a menu, the other does something at once.
        func chip(_ x: CGFloat, _ width: CGFloat) -> NSRect {
            NSRect(x: x, y: midY - Self.chipHeight / 2, width: width, height: Self.chipHeight)
        }
        out.button = chip(x, buttonWidth)
        x += buttonWidth + Self.chipGap
        out.language = chip(x, languageChipWidth)
        // The chevron's strip, cut off the right end: the icon keeps the 30
        // points it would have had as a chip of its own, so pressing the icon
        // feels exactly like pressing 长图 or 选文字, and the strip is the extra
        // 16 points that were added beside it.
        out.languageMenu = NSRect(x: out.language.maxX - Self.languageMenuWidth,
                                  y: out.language.minY,
                                  width: Self.languageMenuWidth,
                                  height: out.language.height)
        // Four points from `译`, not ten: the two answer one question — which
        // language, and where the answer goes — and a group seam between them
        // would say they belong to two different kinds of thing.
        x += languageChipWidth + Self.chipGap
        out.presentation = chip(x, presentationChipWidth)
        out.presentationMenu = NSRect(x: out.presentation.maxX - Self.languageMenuWidth,
                                      y: out.presentation.minY,
                                      width: Self.languageMenuWidth,
                                      height: out.presentation.height)
        x += presentationChipWidth + Self.barGap
        out.long = chip(x, Self.chipWidth)
        x += Self.chipWidth + Self.chipGap
        out.read = chip(x, Self.chipWidth)
        x += Self.chipWidth + Self.chipGap
        out.colour = chip(x, Self.chipWidth)
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
        // The checkmark takes the far end, in the same 30-point box as the six
        // beside it and a full gap away from them: it is the only one here that
        // ends the capture rather than describing it, and the gap is how the row
        // says so without a divider.
        out.confirm = chip(out.edit.maxX + Self.barGap, confirmWidth)
        // What ends a reading hangs off the capsule's own right inset rather
        // than off `编辑`. The two are the same point only while something was
        // drawn beyond the buttons — a word was, until it went — and anchored to
        // the last button the collapsed bar would end with a chip-wide hole and
        // the one button that finishes a reading would be the only one in this
        // app not touching the edge.
        let lastButton = out.capsule.maxX - Self.barPadding
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
        // The pill is the same check the icon row ends on: one chip, one shape,
        // whatever the line beside it says. Its width used to follow a word, so
        // a language with a longer word moved the button under a hand already
        // reaching for it; a fixed chip cannot.
        out.done = NSRect(x: lastButton - Self.chipWidth,
                          y: midY - Self.chipHeight / 2,
                          width: Self.chipWidth, height: Self.chipHeight)
        // The ✕ is the chips' own box — 30 × 26, one chip gap from the pill —
        // because three buttons in a row are three buttons, whatever they do.
        //
        // It was 22 × 22 for two years, then 26 × 26 for an evening, and both
        // were defended with the same argument: a smaller box cannot pass for a
        // second button, and the exit is not that. The argument is sound about
        // *emphasis* and wrong about *geometry*: with one box shorter and
        // narrower than its neighbours, and a gap of ten on one side against
        // four on the other, the row stops being a row — reported as
        // 「这个图标的大小也不一致啊」, then as 「这三个按钮的距离也不一样大」, then
        // spelled out: 「距离大小、宽度、高度，理论上都应该是一样的」. Emphasis is
        // carried by the fill (clay or not) and by the mark, never by the plate;
        // the plate is the same plate everywhere in this bar.
        out.close = NSRect(x: out.done.minX - Self.chipGap - Self.chipWidth,
                           y: midY - Self.chipHeight / 2,
                           width: Self.chipWidth, height: Self.chipHeight)
        // The extra exit goes to the LEFT of the ✕, so neither the ✕ nor the
        // check ever moves — a ✕ that shifts under a hand reaching for it is
        // the one thing this bar's geometry has always refused to do.
        out.second = NSRect(x: out.close.minX - Self.chipGap - Self.chipWidth,
                            y: midY - Self.chipHeight / 2,
                            width: Self.chipWidth, height: Self.chipHeight)

        guard panelOpen, mode == .shot else { return out }
        let pad: CGFloat = 10
        let rowHeight: CGFloat = 26
        switch panel {
        case .ratio:
            // Three by three: the nine shapes are exactly a square, and a menu
            // of nine rows for something chosen by silhouette is a menu read as
            // a list.
            let chipWidth = (CropAspect.allCases
                .map { textWidth($0.title, Self.chipFont) }.max() ?? 40) + 26
            let space: CGFloat = 6
            let panelWidth = pad * 2 + chipWidth * 3 + space * 2
            let panelHeight = pad * 2 + rowHeight * 3 + space * 2
            let panelX = min(max(8, out.button.midX - panelWidth + 16),
                             bounds.width - panelWidth - 8)
            out.panel = NSRect(x: panelX, y: out.capsule.maxY + 8,
                               width: panelWidth, height: panelHeight)
            for (index, option) in CropAspect.allCases.enumerated() {
                let rect = NSRect(x: panelX + pad + CGFloat(index % 3) * (chipWidth + space),
                                  y: out.panel.maxY - pad - rowHeight
                                    - CGFloat(index / 3) * (rowHeight + space),
                                  width: chipWidth, height: rowHeight)
                out.options.append((option, rect))
            }
        case .language:
            // A list, not a grid: languages are read, and one row per language
            // is the only arrangement in which "which am I on" is a glance
            // rather than a scan. Only the shortlist is in it — a menu with all
            // ten would be a menu with nine things in it nobody chose.
            let codes = TranslationTargets.chosen
            let names = codes.compactMap { TranslationCatalogue.named($0)?.name }
            // Room for the tick on the right of the current one, which is
            // drawn rather than laid out, so it cannot push anything.
            let rowWidth = (names.map { textWidth($0, Self.chipFont) }.max() ?? 60) + 40
            let space: CGFloat = 4
            let panelWidth = pad * 2 + rowWidth
            let panelHeight = pad * 2 + CGFloat(names.count) * rowHeight
                + CGFloat(max(0, names.count - 1)) * space
            // Hangs off its own chip's left edge, the way a menu does, and is
            // pulled back inside the screen when that chip is near the edge.
            let panelX = min(max(8, out.language.minX), bounds.width - panelWidth - 8)
            out.panel = NSRect(x: panelX, y: out.capsule.maxY + 8,
                               width: panelWidth, height: panelHeight)
            for (index, code) in codes.enumerated() {
                let rect = NSRect(x: panelX + pad,
                                  y: out.panel.maxY - pad - rowHeight
                                    - CGFloat(index) * (rowHeight + space),
                                  width: rowWidth, height: rowHeight)
                out.languageRows.append((code, rect))
            }
        case .presentation:
            // Two rows, and the same list shape as the language menu: the two
            // answers are read, not recognised by silhouette, and a row each is
            // what makes "which am I on" a glance.
            let names = Presentation.all.map(\.name)
            let rowWidth = (names.map { textWidth($0, Self.chipFont) }.max() ?? 60) + 40
            let space: CGFloat = 4
            let panelWidth = pad * 2 + rowWidth
            let panelHeight = pad * 2 + CGFloat(names.count) * rowHeight
                + CGFloat(max(0, names.count - 1)) * space
            let panelX = min(max(8, out.presentation.minX), bounds.width - panelWidth - 8)
            out.panel = NSRect(x: panelX, y: out.capsule.maxY + 8,
                               width: panelWidth, height: panelHeight)
            for (index, mode) in Presentation.all.enumerated() {
                let rect = NSRect(x: panelX + pad,
                                  y: out.panel.maxY - pad - rowHeight
                                    - CGFloat(index) * (rowHeight + space),
                                  width: rowWidth, height: rowHeight)
                out.presentationRows.append((mode, rect))
            }
        case .none:
            break
        }
        return out
    }

    /// `1240 pt` — how tall the picture has grown, in points.
    ///
    /// Points rather than pixels: the number is read while scrolling, and what
    /// it has to compare against is the text on the screen behind it, which is
    /// measured in points too.
    private var middleLabel: String {
        // The same slot a reading fills with its length. A hex is what this
        // answer *is*, and the bar was empty without it.
        if let colourResult { return ColourSampler.hex(colourResult.colour) }
        if translating { return "" }
        // The unit belongs to the script, not to the tool: an English result
        // counts words, a Chinese or Japanese one counts characters.
        if let translationText { return ResultCount.label(for: translationText) }
        if let state = readingState {
            switch state {
            case .going: return L("Reading…")
            case .nothing: return L("No text found")
            case .found(let text): return ResultCount.label(for: text)
            }
        }
        if let previewLong { return "\(previewLong) pt" }
        guard mode == .long, stitcher.count > 0 else { return "" }
        let points = Int((Double(stitcher.height) / screen.backingScaleFactor).rounded())
        return "\(points) pt"
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
        if colourResult != nil { return true }
        if case .found = readingState { return true }
        return false
    }

    /// What the second exit hands over, when there is one.
    ///
    /// A reading has one answer — the check. A *translated* reading has two
    /// things worth taking: the picture the words were painted on (in place), or
    /// the two texts side by side (the card). Which one is on offer is a fact
    /// about the state rather than about the button, and it is asked from one
    /// place so the drawing, the hit test and the harness cannot disagree about
    /// what is in that slot.
    private enum SecondExit {
        case picture(CGImage)
        case both(words: String, translation: String)

        var symbol: String {
            switch self {
            case .picture: return CaptureSymbol.hangImage
            case .both: return CaptureSymbol.bothTexts
            }
        }

        /// What this slot hands over, for the one control in the folded bar
        /// whose symbol cannot say it alone.
        var tip: String {
            switch self {
            case .picture: return L("The translated picture")
            case .both: return L("Both texts · the words and their translation")
            }
        }
    }

    private var secondExit: SecondExit? {
        if let image = inPlaceImage { return .picture(image) }
        // Both, only when there really are two different strings: the check
        // already hands over the answer, and a button that copies the same
        // words twice would be a button lying about having a second thing.
        guard let words = wordsText, let translated = translationText,
              !words.isEmpty, !translated.isEmpty, words != translated else { return nil }
        return .both(words: words, translation: translated)
    }

    /// Whether there is anything for the check to do.
    ///
    /// Ending a long capture always is. Taking words away only once they exist:
    /// while the read is still going there is nothing to take, and a check
    /// agreeing with an answer not yet given would be a check that lies.
    /// The three words this pill used to wear — `完成`, `确认`, `复制` — all
    /// described the same act, so the line beside it says which one it is
    /// and the check says only "go".
    private var pillLive: Bool {
        // `growing` rather than `mode == .long`: the harness has no long mode to
        // be in — it sets `previewLong` and renders the same bar — and a pill
        // that exists on a real screen and not in a picture of one is a preview
        // that cannot be trusted about the one thing it is for.
        if growing { return true }
        if colourResult != nil { return true }
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
    var shotBarOnScreen: (capsule: NSRect, ratio: NSRect, language: NSRect,
                          languageMenu: NSRect, presentation: NSRect,
                          presentationMenu: NSRect, long: NSRect, read: NSRect,
                          colour: NSRect, edit: NSRect,
                          again: NSRect, confirm: NSRect)? {
        guard mode == .shot, readingState == nil else { return nil }
        let bar = bar()
        guard !bar.read.isEmpty else { return nil }
        let origin = screen.frame.origin
        return (bar.capsule.offsetBy(dx: origin.x, dy: origin.y),
                bar.button.offsetBy(dx: origin.x, dy: origin.y),
                bar.language.offsetBy(dx: origin.x, dy: origin.y),
                bar.languageMenu.offsetBy(dx: origin.x, dy: origin.y),
                bar.presentation.offsetBy(dx: origin.x, dy: origin.y),
                bar.presentationMenu.offsetBy(dx: origin.x, dy: origin.y),
                bar.long.offsetBy(dx: origin.x, dy: origin.y),
                bar.read.offsetBy(dx: origin.x, dy: origin.y),
                bar.colour.offsetBy(dx: origin.x, dy: origin.y),
                bar.edit.offsetBy(dx: origin.x, dy: origin.y),
                bar.again.offsetBy(dx: origin.x, dy: origin.y),
                bar.confirm.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// Opens a panel and says where its rows are, for the harness.
    ///
    /// A capture's panels are the one part of this bar a render cannot reach by
    /// pressing: there is no pointer in a render, and these rows are the answer
    /// to a question about settings that are on disk.
    func openPanelForTesting(_ name: String) -> Bool {
        switch name {
        case "ratio": panel = .ratio
        case "language": panel = .language
        case "presentation": panel = .presentation
        default: return false
        }
        needsDisplay = true
        return true
    }

    /// The menu's rows as drawn: language code and where it sits, in screen
    /// coordinates. Empty unless the language panel is open.
    var languageRowsOnScreen: [(code: String, rect: NSRect)] {
        guard panel == .language else { return [] }
        let origin = screen.frame.origin
        return bar().languageRows.map {
            ($0.0, $0.1.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    /// The blocks an in-place answer is arriving in, top first, for the harness.
    /// Order is the whole effect the animation is for, and it is the one part of
    /// it a still picture cannot show.
    var inPlaceBoxesForTesting: [CGRect] { inPlaceBoxes }

    /// Which languages the menu would offer, without opening it.
    var offeredLanguagesForTesting: [String] { TranslationTargets.chosen }

    /// The language this capture is set to, and what the bar is saying about it.
    ///
    /// A window with no word on the chip has no other way to be asked "which one
    /// is in force": the pixel that would say it is the panel's clay row, and the
    /// panel is shut while `T` walks.
    var languageForTesting: String { translationLanguage }
    var saidNoteForTesting: String? { saidNote }

    /// The chip's own width, so the harness can compare two answers.
    var languageChipWidthOnScreen: CGFloat {
        guard mode == .shot else { return 0 }
        return bar().language.width
    }

    /// The presentation menu's rows as drawn: which way and where it sits, in
    /// screen coordinates. Empty unless that menu is open.
    var presentationRowsOnScreen: [(way: String, rect: NSRect)] {
        guard panel == .presentation else { return [] }
        let origin = screen.frame.origin
        return bar().presentationRows.map {
            ($0.0 == .card ? "card" : "inPlace", $0.1.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    /// Where the reading state's pill and ✕ sit, in screen coordinates.
    ///
    /// Handed out for the same reason the two above are: the harness has to ask
    /// the live arithmetic instead of keeping a copy of it. A button drawn in
    /// one place and pressed in another is exactly what a second copy of this
    /// arithmetic buys.
    var readingBarOnScreen: (capsule: NSRect, close: NSRect, done: NSRect,
                             second: NSRect)? {
        guard readingState != nil, !translating else { return nil }
        let bar = bar()
        let origin = screen.frame.origin
        return (bar.capsule.offsetBy(dx: origin.x, dy: origin.y),
                bar.close.offsetBy(dx: origin.x, dy: origin.y),
                bar.done.offsetBy(dx: origin.x, dy: origin.y),
                bar.second.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// What the second exit would hand over at this instant, for the harness.
    /// Nil when the chip is not drawn at all.
    var secondExitNameForTesting: String? {
        switch secondExit {
        case .picture: return "picture"
        case .both: return "both"
        case nil: return nil
        }
    }

    /// What the pointer would say over a control of the folded bar, for the
    /// harness.
    ///
    /// A tool tip is the one part of this bar nobody can see in a still, and it
    /// is the only thing that explains the second exit's symbol — the folded bar
    /// has no other room for a word (2026-11-13). Asked from the same
    /// `chipName` the window server asks, with the point computed here so a tip
    /// that stopped being offered over a drawn control fails a check instead of
    /// going quiet.
    func chipNameForTesting(_ name: String) -> String? {
        let bar = bar()
        switch name {
        case "second":
            guard !bar.second.isEmpty else { return nil }
            return chipName(at: NSPoint(x: bar.second.midX, y: bar.second.midY))
        case "close":
            return chipName(at: NSPoint(x: bar.close.midX, y: bar.close.midY))
        case "done":
            return chipName(at: NSPoint(x: bar.done.midX, y: bar.done.midY))
        default:
            return nil
        }
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

    /// Harness only: the state between "asked" and "answered", which is the
    /// only moment the bar says which language it is working in. No engine is
    /// called — the claim is about the sentence, not about the round trip.
    func markTranslatingForTesting() {
        translating = true
        needsDisplay = true
    }

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
            // The second exit, when there is one, takes the same room the
            // readout would have used; a number under a button is a number
            // nobody can read.
            let readoutEdge = secondExit != nil ? bar.second.minX : bar.close.minX
            let numbers = NSRect(x: bar.button.minX, y: bar.middle.minY,
                                 width: max(0, readoutEdge - Self.barGap - bar.button.minX),
                                 height: bar.middle.height)
            draw(bar.middleText, in: numbers,
                 attributes: [.font: Self.buttonFont,
                              .foregroundColor: CaptureInk.ink(effectiveAppearance)
                                  .withAlphaComponent(0.88)],
                 centred: true)

            // The one pressable thing that changes what happens, and the only
            // way forward that does not need a keyboard. It is the same clay
            // check the icon row ends on: a long capture, a reading and a
            // translation all end by handing something over, so one shape says
            // all three. The hover ring is the only pointer feedback this app
            // can give here: while a long capture runs it is not frontmost, and
            // a background app is not allowed to set the cursor.
            if pillLive { drawConfirmChip(bar.done, hover: doneHover) }

            // The ✕, which is never the thing to do and is always available. It
            // is drawn whether or not the pill is, so the way out does not
            // appear and disappear while a read finishes.
            if let second = secondExit {
                drawChip(bar.second, symbol: second.symbol, key: nil)
            }
            drawClose(bar.close, lit: closeHover)
        } else {
            // Two kinds of chip, drawn in the order they are laid out: the three
            // that carry a value or a menu, then the four that are only a
            // symbol with a key in the corner. The words were abandoned because
            // the capsule was reading as a paragraph with a toolbar on the end;
            // a symbol says the same thing in 30 points, and the letter in the
            // corner is the only part of this bar a person has to be taught.
            drawRatioChip(bar.button)
            drawLanguageChip(bar.language, menu: bar.languageMenu)
            drawPresentationChip(bar.presentation, menu: bar.presentationMenu)
            // The armed chip fills, exactly the way the ratio chip fills when a
            // shape is locked. One rule for the whole bar: filled means "this
            // changes what the next drag means" — so pressing L, W or T has to
            // light the button it stands for, or the key is the only thing on
            // screen saying anything happened. Reported the day after the icons
            // landed, and rightly: `R` filled its chip and the other three keys
            // looked like they had done nothing.
            drawChip(bar.long, symbol: CaptureSymbol.long, key: "L", picked: isPicked(.long))
            drawChip(bar.read, symbol: CaptureSymbol.read, key: "W", picked: isPicked(.read))
            drawChip(bar.colour, symbol: CaptureSymbol.colour, key: "I",
                     picked: isPicked(.colour))
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
            // The checkmark, and the only filled chip in this row that is not
            // saying "this mode is on". Clay is what this app uses for "this is
            // the thing to press" — the same colour the pill wears when it ends
            // a reading — so the one button that finishes the capture is the one
            // painted like a button rather than drawn like a symbol. No key in
            // its corner: Return already belongs to it, and the keys that are
            // spelled out are the ones nobody would guess.
            // No check while aiming: there is nothing to take yet, and a clay
            // button that answers nothing is a button that looks broken.
            if !colourAiming { drawConfirmChip(bar.confirm) }
        }

        guard panelOpen, mode == .shot else { return }
        // Ten, where a button has seven: the panel is the sheet the buttons sit
        // on, and a sheet drawn with a button's corner is one enormous chip.
        let shape = NSBezierPath(roundedRect: bar.panel, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        CaptureInk.panel(effectiveAppearance).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.12).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        switch panel {
        case .ratio:
            for (option, rect) in bar.options {
                let chip = NSBezierPath(roundedRect: rect,
                                        xRadius: Self.chipRadius, yRadius: Self.chipRadius)
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
        case .language:
            drawMenuRows(bar.languageRows.map {
                (title: TranslationCatalogue.named($0.0)?.name ?? $0.0,
                 picked: $0.0 == translationLanguage, rect: $0.1)
            })
        case .presentation:
            // The same two marks, in the same shape, because it is the same
            // question: which of these is in force. Nothing else here differs —
            // a menu that looked different for being two rows long would be a
            // second kind of menu in one bar.
            drawMenuRows(bar.presentationRows.map {
                (title: $0.0.name, picked: $0.0 == presentation, rect: $0.1)
            })
        case .none:
            break
        }
    }

    /// A menu's rows: the faint wash every row wears, the word, and a clay
    /// wash plus a tick on the one in force.
    ///
    /// The tick as well as the wash, because the wash is a tint on a tint: on a
    /// light panel it is nearly nothing, and a menu where the current item is
    /// nearly nothing is a menu that has to be read twice. A faint wash on every
    /// row and not only the chosen one, because a menu of bare text says nothing
    /// about where one row ends and the next begins.
    private func drawMenuRows(_ rows: [(title: String, picked: Bool, rect: NSRect)]) {
        for row in rows {
            let rect = row.rect
            // The chip's own corner, not a point tighter: every row in this
            // panel is a button, and the panel it sits in is the only thing
            // here that is not.
            let shape = NSBezierPath(roundedRect: rect,
                                     xRadius: Self.chipRadius, yRadius: Self.chipRadius)
            (row.picked ? CDS.clayInk
                        : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.07)).setFill()
            shape.fill()
            draw(row.title, in: NSRect(x: rect.minX + 10, y: rect.minY,
                                       width: rect.width - 40, height: rect.height),
                 attributes: [.font: Self.chipFont,
                              .foregroundColor: row.picked
                                  ? CaptureInk.onClay
                                  : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.9)])
            guard row.picked, let tick = Self.glyph("checkmark", pointSize: 11,
                                                    ink: CaptureInk.onClay) else { continue }
            tick.draw(in: NSRect(x: rect.maxX - 10 - tick.size.width,
                                 y: rect.midY - tick.size.height / 2,
                                 width: tick.size.width, height: tick.size.height))
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
    private static func glyph(_ symbol: String, pointSize: CGFloat, ink: NSColor,
                              weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(symbol)-\(pointSize)-\(weight.rawValue)-\(inkCacheKey(ink))"
        if let cached = glyphs[key] { return cached }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
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
    ///
    /// `translate` and `presentation` were two chips because they are two
    /// answers, and a key that armed one had to light **that** chip. Only one
    /// of them can be filled now: the globe is a select box (2026-11-13,
    /// 「只是一个选择框」) and selecting a language arms nothing, while the chip
    /// that says where the words land still waits for an area if it is pressed
    /// early. A globe that filled would be claiming a mode it does not have.
    private func isPicked(_ chip: Choice) -> Bool {
        switch chip {
        case .ratio: return aspect != .free
        case .long: return longArmed
        case .read: return readArmed
        case .translate: return false
        case .presentation: return translateArmed
        case .colour: return colourAiming || colourResult != nil
        }
    }

    /// The chips that can be filled. `编辑` and `重截` cannot: one ends the
    /// capture by taking it, the other by putting a frame back, and neither
    /// changes what the next drag means.
    enum Choice: String, CaseIterable {
        case ratio, long, read, translate, presentation, colour
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
        // The only armed state translation still has: the key pressed before
        // the area. `"translate"` is gone with the door it named — the globe
        // has no mode to show, so a preview cannot be asked to draw one.
        case "presentation": translateArmed = true
        case "inPlace": presentation = .inPlace
        case "colour": colourAiming = true
            colourHover = colourHover ?? NSPoint(x: bounds.midX, y: bounds.midY)
        // Not an arming either, but it has to be holdable for a photograph:
        // `restore` is what normally lights this, and a preview has no click.
        case "again": againShowing = true
        default: break
        }
    }

    /// Harness only: the picker in hand, with the loupe on a known point. A
    /// render has no pointer to move, and a click has to land on the same
    /// pixel the magnifier is showing.
    func aimColourForTesting(_ point: NSPoint) {
        armColour()
        colourHover = point
        needsDisplay = true
    }
    func takeColourForTesting(_ point: NSPoint) { takeColour(at: point) }
    func finishColourForTesting() { finishResult() }

    /// One symbol, centred on a point, at the bar's one mark size.
    ///
    /// The five drawings that used to centre an image by hand each carried their
    /// own point size and their own two subtractions. A helper is the only shape
    /// in which "all the marks are the same size" is a fact rather than a promise
    /// kept in five places — and the promise was broken in four of them, which is
    /// what the row looked like (2026-11-13).
    ///
    /// `weight` is an argument because exactly one mark in the bar is not the
    /// bar's weight: the tick, on clay. Everything else takes the default.
    private func drawMark(_ symbol: String, at centre: NSPoint, ink: NSColor,
                          weight: NSFont.Weight = .regular) {
        guard let image = Self.glyph(symbol, pointSize: Self.markPointSize,
                                     ink: ink, weight: weight) else { return }
        let size = image.size
        image.draw(in: NSRect(x: centre.x - size.width / 2,
                              y: centre.y - size.height / 2,
                              width: size.width, height: size.height))
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
        let box = NSBezierPath(roundedRect: rect,
                               xRadius: Self.chipRadius, yRadius: Self.chipRadius)
        (picked ? CDS.clayInk
                : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.10)).setFill()
        box.fill()
        let ink = picked ? CaptureInk.onClay
                         : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.92)
        drawMark(symbol, at: NSPoint(x: rect.midX, y: rect.midY), ink: ink)
        if let key, showKeys {
            // On clay the letter has to go dark, for the same reason the icon
            // does: white on clay is not faint, it is gone.
            drawHint(key, in: rect, onClay: picked)
        }
    }

    /// The chip beside `译`: which way the words come back.
    ///
    /// Built exactly like `译` — a symbol in the 30 points a chip has, a chevron
    /// in the 16 beside it — because the two answer one question asked twice:
    /// *which* language, and *where* the answer goes. The symbol changes with
    /// the answer (`CaptureSymbol.presentationCard` / `.presentationInPlace`),
    /// so the chip says what it will do before it is pressed.
    ///
    /// Its icon translates, exactly like `译`'s does: the answer is already
    /// chosen — one of the two is always in force — so pressing must act rather
    /// than ask. Reported the same evening (2026-11-13): 「理论上是默认选择的…
    /// 点一下就应该是确认了」. Only the 16-point chevron opens the menu.
    ///
    /// Never clay *for having an answer*: filled means "this changes what the
    /// next drag means", and one of the two ways is always in force, so a chip
    /// lit because it holds a setting would outrank the three modes that come
    /// and go beside it.
    ///
    /// Armed is the other thing, and it is clay: `M` arms this chip the way `T`
    /// arms `译`, and a key whose press lights nothing is the failure this bar
    /// has already been fixed for twice (`R` filled its chip and `L`/`W`/`T`
    /// filled none). The light goes out the moment the drag it asked for begins,
    /// so the chip is not claiming to be a mode — it is claiming to have heard
    /// the key.
    private func drawPresentationChip(_ rect: NSRect, menu: NSRect) {
        let armed = isPicked(.presentation)
        (armed ? CDS.clayInk
               : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.10)).setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: Self.chipRadius, yRadius: Self.chipRadius).fill()
        let ink = armed ? CaptureInk.onClay
                        : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.92)
        // Centred in the 30 points a chip has, the way `译`'s symbol is: the
        // extra 16 are beside the symbol, not around it.
        let body = NSRect(x: rect.minX, y: rect.minY,
                          width: rect.width - menu.width, height: rect.height)
        let symbol = presentation == .card
            ? CaptureSymbol.presentationCard : CaptureSymbol.presentationInPlace
        // A point and a half to the left of centre: `translate` is the widest
        // glyph here and its rear bubble ends exactly where the `M` goes. One
        // point of width is the difference between a hint and a smudge, and a
        // point and a half inside a 30-point body is not a lean. Both faces share
        // the setting — a chip whose symbol moved when the answer changed would
        // be worse than one that is a point small.
        drawMark(symbol, at: NSPoint(x: body.midX - 1.5, y: rect.midY), ink: ink)
        drawChevron(centre: NSPoint(x: menu.midX, y: rect.midY + 1.5), ink: ink)
        if showKeys { drawHint("M", in: body, onClay: armed) }
    }

    /// The chevron that says "there is a menu here", at one size and one weight
    /// for the whole bar.
    ///
    /// Drawn rather than a glyph: "▾" is not in every font, and the one that has
    /// it sets it at the wrong weight for a 26-point box. Three chips carry one
    /// now, and a chevron that differed by half a point between neighbours would
    /// read as two different kinds of control.
    private func drawChevron(centre: NSPoint, ink: NSColor) {
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: centre.x - 3.5, y: centre.y + 2))
        chevron.line(to: NSPoint(x: centre.x, y: centre.y - 1.5))
        chevron.line(to: NSPoint(x: centre.x + 3.5, y: centre.y + 2))
        chevron.lineWidth = 1.4
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        ink.setStroke()
        chevron.stroke()
    }

    /// The checkmark at the far end: clay, a tick, and nothing else.
    ///
    /// Not `drawChip` with another symbol, because one thing about it is
    /// different in kind: it is the only chip in this row that is filled while
    /// no mode is on. Filled means "this changes what the next drag means"
    /// everywhere else in the bar — here it means "this is the button". No
    /// letter in the corner either: `Return` already belongs to this act.
    ///
    /// The same shape is drawn again at `bar.done` once a reading is in hand.
    /// Those two never appear together — the icon row is replaced by the line
    /// and the check — so there is one check in the app, not two kinds of one.
    private func drawConfirmChip(_ rect: NSRect, hover: Bool = false) {
        let box = NSBezierPath(roundedRect: rect,
                               xRadius: Self.chipRadius, yRadius: Self.chipRadius)
        CDS.clayInk.setFill()
        box.fill()
        // The bar's mark size, and semibold rather than the bar's regular weight:
        // at 13 points a regular tick on clay is a hair, and the one button that
        // ends the capture should not be the faintest mark in the row. Twelve
        // points was this tick alone at a size of its own — 10.25 of ink beside
        // the chips' 12, which is half of what the row was reported for.
        drawMark("checkmark", at: NSPoint(x: rect.midX, y: rect.midY),
                 ink: CaptureInk.onClay, weight: .semibold)
        if hover {
            // White on clay in both appearances: a near-black ring in light
            // mode would read as a pressed border rather than as "this is it".
            NSColor.white.withAlphaComponent(0.55).setStroke()
            box.lineWidth = 1.5
            box.stroke()
        }
    }

    /// The key, bottom right, in the faintest ink that still holds at 6.5 pt.
    ///
    /// Drawn last and over the symbol, which is how the editor's chips do it: on
    /// a glyph that fills its box the letter sits on the shape rather than
    /// beside it, and at this size that is the difference between a hint and a
    /// smudge. `onClay` is the one chip whose ground is clay rather than ink,
    /// and a white letter on clay is not a faint hint — it is an absent one.
    /// `rightEdge` existed for the one chip that was two targets in one box with
    /// a word in it. Nothing needs it now; kept as a parameter would be an
    /// argument nobody passes.
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
        let bar = bar()
        // While a reading is up the row is folded to three controls, and one of
        // them is a symbol nobody has met before: 「both texts」 has no glyph in
        // the system that says it (2026-11-13), so the words have to be one
        // hover away. The ✕ is named in the same breath — a bar where hovering
        // works on one button of three is a bar with a hole in it. The check is
        // not: 「go」 is the one thing a check has never needed explaining.
        if collapsed {
            if let second = secondExit, bar.second.contains(local) { return second.tip }
            if bar.close.contains(local) { return L("Leave without taking it") }
            return nil
        }
        if bar.languageMenu.contains(local) {
            return L("Language · which one it translates into")
        }
        if bar.button.contains(local) { return L("Ratio · the shape of the frame") }
        if bar.long.contains(local) { return L("Long · scroll down, Return when done") }
        if bar.read.contains(local) { return L("Text · the words in the area") }
        // The button's name and nothing more. No sentence explaining when to
        // press it: the loupe answers that the moment it is pressed.
        if bar.colour.contains(local) { return L("Colour Picker") }
        // The chip no longer says which language, and the menu is a press away
        // rather than a glance — so the answer is here instead, where hovering
        // costs nothing and looking is what a person is already doing.
        if bar.language.contains(local) {
            let name = TranslationCatalogue.named(translationLanguage)?.name ?? translationLanguage
            return L("Language · which one it translates into") + " · " + name
        }
        // The chip beside it says where the answer lands — and says it by doing
        // it. The two halves have two jobs now (2026-11-13, the third telling):
        // the body translates and the chevron opens the two rows. Before that
        // both halves only opened the menu, which left the person pressing the
        // chip and then a check, and calling the second press 多余.
        if bar.presentation.contains(local) {
            if bar.presentationMenu.contains(local) {
                return L("Where the translation goes") + " · " + presentation.name
            }
            return L("Translate") + " · " + presentation.name
        }
        if bar.edit.contains(local) { return L("Edit · take it and open the editor") }
        if againShown, bar.again.contains(local) { return L("Again · put the last frame back") }
        // The way out is here now. It used to be a word at the end of the bar,
        // said to everyone all the time; it is said to the person asking about
        // this button instead, at the one moment they are asking.
        if bar.confirm.contains(local) {
            // One press, one question: with a translation waiting for an area
            // this button no longer takes a picture, and a tip that still said
            // 截图 would be the old answer at the worst moment.
            if translateArmed {
                return L("Translate · Return, a double-click, or this button · esc leaves")
            }
            return L("Capture · Return, a double-click, or this button · esc leaves without one")
        }
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
        let box = NSBezierPath(roundedRect: rect,
                               xRadius: Self.chipRadius, yRadius: Self.chipRadius)
        (locked ? CDS.clayInk
                : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.10)).setFill()
        box.fill()
        let ink = locked ? CaptureInk.onClay
                         : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.92)
        // Left-anchored rather than centred, which is why this one does not go
        // through `drawMark`: the word beside it has to start where the symbol
        // ends, and the symbol's box is wider than its ink.
        if let image = Self.glyph(CaptureSymbol.ratio, pointSize: Self.markPointSize, ink: ink) {
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
        drawChevron(centre: NSPoint(x: rect.maxX - 12, y: rect.midY + 1.5), ink: ink)
        if showKeys { drawHint("R", in: rect, onClay: locked) }
    }

    /// The language chip: one icon, one chevron, and the only chip in the row
    /// that is two targets.
    ///
    /// The split is the point. Nine presses out of ten want the same language as
    /// last time, and that press must not cost a menu; the tenth wants another
    /// one, and that press must not cost a trip to Settings. So the icon
    /// translates and the 16 points beside it open the shortlist.
    ///
    /// No hairline between the halves, unlike the first version: with no word
    /// between them the two are four points apart, and a 1-point line in a gap
    /// that narrow does not read as a seam — it reads as a crack. What says
    /// "there is a menu here" is the chevron, which is the same drawn chevron
    /// the ratio chip uses for the same reason.
    ///
    /// `T` sits in the icon's corner, not the chip's: the key does what the icon
    /// does, and the corner of the whole box is inside the menu's strip. The
    /// strip has no letter: `Y` was here for a fortnight and is gone — 「我觉得
    /// 这个 Y 的快捷键没有意义，这就是手工选就行了」(2026-11-13). The menu is a
    /// mouse target, and a key nobody asked for is a corner spent on nothing.
    private func drawLanguageChip(_ rect: NSRect, menu: NSRect) {
        let armed = isPicked(.translate)
        let box = NSBezierPath(roundedRect: rect,
                               xRadius: Self.chipRadius, yRadius: Self.chipRadius)
        (armed ? CDS.clayInk
               : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.10)).setFill()
        box.fill()
        let ink = armed ? CaptureInk.onClay
                        : CaptureInk.ink(effectiveAppearance).withAlphaComponent(0.92)
        // Centred in the 30 points a chip has, so the icon lands exactly where
        // 长图's and 选文字's do — the extra 16 are beside it, not around it.
        let body = NSRect(x: rect.minX, y: rect.minY,
                          width: rect.width - menu.width, height: rect.height)
        drawMark(CaptureSymbol.translate, at: NSPoint(x: body.midX, y: rect.midY), ink: ink)
        // The same drawn chevron every other chipped menu uses, at the same
        // size: two chevrons in one bar that differ by half a point read as two
        // different kinds of control, and 16 points has room for the wider one.
        drawChevron(centre: NSPoint(x: menu.midX, y: rect.midY + 1.5), ink: ink)
        // One letter, because there is one key: the body translates, and the
        // 16-point strip beside it is the mouse's alone.
        if showKeys {
            drawHint("T", in: body, onClay: armed)
        }
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
        if hasResult {
            // The bar is the only thing with an answer here, and the card is not
            // a way to start a new rectangle: a press on the words would
            // otherwise draw a frame under a result that is still being decided
            // about — and the rectangle drawn by a press meant to dismiss
            // something is the oldest way to lose work in this window.
            _ = takeBarClick(at: local)
            return
        }
        if colourAiming {
            // One click, one pixel. No drag, no frame, and no second press to
            // say "yes" to the pixel — the check on the bar says that instead.
            takeColour(at: local)
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
        if hasResult {
            // Said with the geometry: "the copy button does nothing" is the same
            // report for a press that missed the pill and a press the pill
            // refused, and only one of those is worth fixing.
            diagLog("Capture text: bar press at \(Int(local.x)),\(Int(local.y))"
                + " — pill \(Int(bar.done.minX))…\(Int(bar.done.maxX))"
                + "×\(Int(bar.done.minY))…\(Int(bar.done.maxY)),"
                + " live \(pillLive), translating \(translating)")
            // The second exit is a button of its own, and must be answered
            // before the capsule's blanket "take the words" press — otherwise
            // a click meant to take the picture (or the two texts) would take
            // the words instead.
            if let second = secondExit, bar.second.contains(local) {
                switch second {
                case .picture(let image):
                    DispatchQueue.main.async { [weak self] in self?.onFinishInPlaceImage(image) }
                case .both(let words, let translated):
                    // The same landing as the check — pasteboard and one card —
                    // with both texts in it. A second door in the controller
                    // would be a second definition of where a text lands.
                    DispatchQueue.main.async { [weak self] in
                        self?.onFinishTranslation(words + "\n\n" + translated)
                    }
                }
                return true
            }
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
                DispatchQueue.main.async { [weak self] in self?.finishResult() }
            }
            return true
        }
        if panelOpen {
            let closed = panel
            panel = .none
            switch closed {
            case .ratio:
                for (option, rect) in bar.options where rect.contains(local) {
                    aspect = option
                    needsDisplay = true
                    return true
                }
            case .language:
                for (code, rect) in bar.languageRows where rect.contains(local) {
                    translationLanguage = code
                    TranslationTargets.current = code
                    // Logged because a choice that did not land is invisible:
                    // the chip carries no language name, so "I picked English"
                    // and "nothing was picked" look identical on screen. The
                    // question this answers is 「为什么翻译成英文，它翻译成的是
                    // 繁体」 (2026-11-13).
                    diagLog("Capture: 译成 → \(code)")
                    needsDisplay = true
                    // Choosing a language settles *which* one, and nothing else.
                    // It used to run the translation as well, on the theory that
                    // the menu was the press; the person using it disagreed
                    // (2026-11-13): 「选了之后不确认」. Two presses that do one
                    // visible thing each beat one press that does two, because
                    // only the second kind can be taken back.
                    return true
                }
            case .presentation:
                for (way, rect) in bar.presentationRows where rect.contains(local) {
                    presentation = way
                    // Written down here rather than in a `didSet`: this is the
                    // click that chooses, and the harness assigns the property
                    // directly to photograph both faces. A setting that wrote
                    // itself on every assignment would let a test change the
                    // person's choice.
                    Presentation.remember(way)
                    needsDisplay = true
                    // A setting, like the language: choosing says *where*, and
                    // it runs nothing — the ask is the chip's body, `M`, or the
                    // check. The chip's own face changes with this assignment, so
                    // the press is visible even with no area drawn — which the
                    // half of the old two-button segment that answered this
                    // question was not.
                    diagLog("Capture text: translation goes \(way == .card ? "side by side" : "in place")")
                    return true
                }
            case .none:
                break
            }
            if bar.panel.contains(local) {
                needsDisplay = true
                return true          // the panel's own air, not a choice
            }
            needsDisplay = true
            return true              // the press spent itself dismissing the panel
        }
        // The chevron end before the chip: it is inside it, and a menu that
        // could not be opened because the body answered first is a menu that
        // does not exist.
        if bar.languageMenu.contains(local) {
            selectLanguage()
            return true
        }
        // The globe is a select box and nothing else (2026-11-13, twice in one
        // evening: 「其实它没有按钮的作用，只是一个选择框」). Both halves open the
        // list, neither lights anything, neither asks the engine — what is
        // chosen there is read by the next press of the chip beside it.
        if bar.language.contains(local) {
            selectLanguage()
            return true
        }
        // The chevron of the other chip opens its two rows; the body translates.
        // A press that both ran and opened a menu would put a menu over the
        // answer it had just asked for.
        if bar.presentationMenu.contains(local) {
            panel = .presentation
            needsDisplay = true
            return true
        }
        if bar.presentation.contains(local) {
            // 2026-11-13, the third telling: 「按 M 键或者点一下，理论上就该去翻译。
            // ……我还必须再按一下回车键，这就是多余了」. Where the words land is
            // already chosen — there is nothing left to confirm, so the press
            // is the ask.
            translateNow()
            return true
        }
        if bar.button.contains(local) {
            panel = .ratio
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
        if bar.colour.contains(local) {
            armColour()
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
        if bar.confirm.contains(local) {
            // Nothing is drawn there while aiming, but a press reaching this
            // geometry from a stale hit test must not take a picture either.
            if colourAiming { return true }
            // The same act as Return and a double-click, as a button. Deferred a
            // turn for the same reason every other ending is.
            DispatchQueue.main.async { [weak self] in self?.confirm() }
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
            // A menu about a value does not survive a decision about what the
            // next drag means. The person has moved on, and a menu still hanging
            // over the bar hides the chip that just lit.
            panel = .none
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
            panel = .none
            needsDisplay = true
        }
    }

    /// Translates the area, now.
    ///
    /// `M` and a press on the chip that says where the words land are one act.
    /// The person using it, 2026-11-13 evening: 「我们的翻译快捷键是 M 键。按 M 键
    /// 的话就应该直接去做翻译……按 M 键或者点一下，理论上就该去翻译」. Where the
    /// answer goes already has a value in force, so there is nothing left to
    /// confirm — asking for a second press would be asking again for an answer
    /// that is already given.
    ///
    /// The globe beside it is a **selector** and nothing else (see
    /// `selectLanguage`): 「你那个选择语言没有这个功能，所以它只是选择」. Two
    /// chips, one question each, and only this one runs.
    ///
    /// With no area drawn it arms the mode instead, and the next drag translates
    /// where it lands — the same "choose, then draw" the read and long doors
    /// have.
    ///
    /// A result on screen is **not** a reason to refuse. Changing 译成 or the
    /// place it goes is a setting, and the setting does nothing until something
    /// asks again — this press is that ask. Refusing while a reading was up is
    /// how 繁體 and English both came back looking like dead buttons on
    /// 2026-11-13: the language was chosen, the same key was pressed, and
    /// nothing moved. Only a request already in flight is refused, because two
    /// answers for one area can arrive out of order.
    private func translateNow() {
        guard mode == .shot, reading != .going else { return }
        panel = .none
        if let rect = selection {
            beginTranslation(rect)
        } else {
            translateArmed = true
            longArmed = false
            readArmed = false
            diagLog("Capture text: asked before the area — the next one is translated")
            needsDisplay = true
        }
    }

    /// The one place a translation is started, so every entrance to it agrees.
    ///
    /// There are four now — `M`, the chip's body, a drag that followed either of
    /// them, and the check — and a door with four handles and four behaviours is
    /// how the second press got invented in the first place.
    ///
    /// `reading = nil` is not tidiness: `startReading` refuses while a reading
    /// is up, and a reading on screen is exactly what "ask again" has to clear
    /// (change 译成, press once more).
    private func beginTranslation(_ rect: CGRect) {
        reading = nil
        translateArmed = false
        diagLog("Capture text: asked at once, "
            + (presentation == .card ? "side by side" : "in place"))
        startReading(rect, purpose: presentation == .card ? .translate : .inPlace)
    }

    /// The globe: a selection box, and nothing else.
    ///
    /// 2026-11-13, twice in one evening: 「那个地球仪的『选择语言』按钮……它是不能
    /// 有翻译功能的，只有选择功能。其实它没有按钮的作用，只是一个选择框」. So both
    /// halves open the list, neither lights anything, and neither asks the
    /// engine. What it chooses is read by `translateNow`, when that press comes.
    ///
    /// A mode already armed by `M` survives this: setting the language first and
    /// dragging afterwards is one flow, not two.
    private func selectLanguage() {
        guard mode == .shot, reading != .going else { return }
        panel = .language
        needsDisplay = true
    }

    /// `T`: the next language in the shortlist, the way `R` walks the shapes.
    ///
    /// Reported 2026-11-13: 「我们现在用 T 只能跳转到"选择语言"的按钮，但是不能去
    /// 切换语言。…你看你左侧框选比例的选择，按 R 就可以直接跳」. The ratio chip and
    /// this one answer the same kind of question — *which of these is in force* —
    /// and the ratio chip had a key that changed the answer while this one only
    /// had a key that opened a list.
    ///
    /// One target is the floor: with a single language chosen there is nothing to
    /// walk, so the list opens instead. A key that does nothing on some machines
    /// is a key that reads as broken on those machines.
    ///
    /// The choice is written through, like the menu's: a language picked for one
    /// capture and forgotten by the next is not a setting. And it says what it
    /// landed on (`say`) — the chip carries no word, so otherwise two presses and
    /// one press look exactly alike.
    private func cycleLanguage() {
        guard mode == .shot else { return }
        panel = .none
        let codes = languageShortlist
        guard codes.count > 1 else {
            selectLanguage()
            return
        }
        let index = codes.firstIndex(of: translationLanguage).map { $0 + 1 } ?? 0
        let code = codes[index % codes.count]
        translationLanguage = code
        TranslationTargets.current = code
        // Logged for the same reason the menu's choice is: nothing on the chip
        // says which language is in force, so "it did not change" and "it
        // changed twice" are the same picture.
        diagLog("Capture: 译成 → \(code)（T）")
        say(languageNote(code))
        needsDisplay = true
    }

    /// What the bar says when the language is walked to `code`.
    private func languageNote(_ code: String) -> String {
        guard let name = TranslationCatalogue.named(code)?.name else {
            return L("The language changed")
        }
        return String(format: L("Now into %@"), name)
    }

    /// Says something for a moment, then puts the line back.
    ///
    /// Two seconds rather than one: 「译成 繁體中文」 carries a name, and a name is
    /// read rather than recognised. A view without a window is the harness or an
    /// off-screen preview, and it gets no clock at all — the same reason
    /// `noteReveal` takes none: a still that changes under the camera turns every
    /// pixel check into a coin toss.
    private func say(_ note: String) {
        saidNote = note
        needsDisplay = true
        saidTimer?.invalidate()
        saidTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saidNote = nil
                self.saidTimer = nil
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saidTimer = timer
    }

    /// The picture with its words replaced, and those words for the text exit.
    /// The bar keeps its ordinary reading state: the check hands over the words
    /// as text, the extra button hands over the picture.
    ///
    /// `leftBehind` is how many areas the engine had nothing for. They keep
    /// their original words on the picture — painting a cover over them would
    /// lose what they said — so the bar says how many, rather than leaving a
    /// half-translated screenshot to be read as a bad translation.
    ///
    /// `base` and `boxes` are only for the arrival: the area before translation,
    /// and the blocks that were replaced, in the order they are read. Without
    /// them the picture is a still — which is what every pixel check wants, and
    /// what a person watching it did not ask for.
    func showInPlaceTranslation(_ image: CGImage?, words: String, leftBehind: Int = 0,
                                base: CGImage? = nil, boxes: [CGRect] = []) {
        // `readingState`, not `reading`: the guard is here to drop an answer that
        // arrives after the reading was dismissed, and the harness photographs
        // this state through `previewReading` instead.
        guard readingState != nil else { return }
        translating = false
        refusal = nil
        translateNoop = false
        inPlaceImage = image
        inPlaceBase = base
        // Top of the area first. Vision's own order is already roughly this,
        // but "roughly" is what a paragraph split across two columns tests.
        inPlaceBoxes = boxes.sorted { $0.maxY > $1.maxY }
        translateNote = leftBehind > 0
            ? String(format: L("%d areas could not be translated"), leftBehind)
            : nil
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        reading = trimmed.isEmpty ? .nothing : .found(trimmed)
        translation = trimmed.isEmpty ? nil : trimmed
        // Its own key: a second translation of the same area must play again,
        // where the card's key deliberately does not restart on a repaint.
        answerSerial += 1
        noteReveal(key: "in-place:\(answerSerial)", rows: inPlaceBoxes.count,
                   animated: image != nil)
        needsDisplay = true
        diagLog("Capture text: in-place translation \(image == nil ? "failed" : "ready")"
            + (inPlaceBoxes.isEmpty ? "" : " in \(inPlaceBoxes.count) block(s)"))
    }

    /// Nothing on the area is in another language.
    ///
    /// The selection is kept and the reading is dropped, deliberately: the
    /// honest next move is to change 译成 and press `译` again, and a reading
    /// on screen is exactly what stops `译` from being pressable. The sentence
    /// says which next move, and it is the same one the card path says.
    func inPlaceNothingToDo() {
        translating = false
        reading = nil
        translation = nil
        inPlaceImage = nil
        inPlaceBase = nil
        inPlaceBoxes = []
        translateNote = nil
        refusal = nil
        translateNoop = true
        needsDisplay = true
        diagLog("Capture text: in-place — nothing in another language")
    }

    /// The colour door has one order only: choose it, then point at a pixel.
    /// A rectangle already on the screen is not an input to this reading — it
    /// says nothing about which pixel was meant — so it is dropped rather
    /// than reinterpreted as its centre or as an average of its contents.
    private func armColour() {
        guard mode == .shot, reading == nil, colourResult == nil else { return }
        colourAiming = true
        colourResult = nil
        colourCard = nil
        selection = nil
        hovered = nil
        longArmed = false
        readArmed = false
        translateArmed = false
        panel = .none
        // The pointer was already somewhere when the key was pressed; a timer
        // that only reports movement would leave the loupe absent until the
        // hand moved, which is the same lesson `beginTracking` exists for.
        colourHover = lastPointer.map { pointer in
            NSPoint(x: pointer.x - screen.frame.minX, y: pointer.y - screen.frame.minY)
        }
        needsDisplay = true
    }

    /// One click, one pixel. The answer waits on a card until the check agrees.
    private func takeColour(at local: NSPoint) {
        guard colourAiming, bounds.contains(local),
              let colour = ColourSampler.colour(at: colourImagePoint(local), in: backdrop)
        else { return }
        colourAiming = false
        colourResult = (local, colour)
        colourHover = nil
        // The pointer has answered its question; nothing is being watched for
        // a frame any more, and a live hover under a result is a second answer.
        endTracking()
        needsDisplay = true
    }

    /// The answer, on its way out. A colour and a reading end in the same
    /// place — the pasteboard and one text card — but they must not be
    /// confused on the way: a colour that went through `finishReading` would
    /// be handed to the words' door.
    private func finishResult() {
        if let result = colourResult {
            onFinishColour(ColourSampler.hex(result.colour))
            return
        }
        finishReading()
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
        panel = .none
        selection = rect
        hovered = nil
        reading = .going
        // Which door this came in through is remembered here and nowhere else,
        // and it is what every later step asks instead of guessing: one answer,
        // set once, so a copy and a translation can never be interleaved.
        readingPurpose = purpose
        if purpose == .translate || purpose == .inPlace {
            translation = nil
            translating = false
            refusal = nil
            translateNoop = false
            translateNote = nil
            inPlaceImage = nil
            inPlaceBase = nil
            inPlaceBoxes = []
        }
        // The crosshair and the window highlight have nothing to say over a
        // result: the pointer is answering a question now, not choosing an area.
        // It also stops the watch drawing a cursor over a picture that is no
        // longer what is being looked at.
        endTracking()
        if purpose == .inPlace {
            onReadInPlace(rect)
        } else {
            onReadArea(rect)
        }
        needsDisplay = true
        diagLog("Capture text: reading \(Int(rect.width))×\(Int(rect.height)) pt"
            + (purpose == .translate ? ", to translate"
               : purpose == .inPlace ? ", in place" : ""))
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
        // Both translation doors hand their words over as text: the card's
        // check and the in-place picture's check are the same act. Only 识别
        // hangs the words it read.
        guard readingPurpose != .hang else {
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
        // An answer that is still the words that were sent is not a translation.
        // It used to be reported as 「已经是这种语言了」, which is a different
        // fact altogether: on 2026-11-14 a model asked for 简体中文 handed the
        // English line straight back six times in a row, and the bar told the
        // person their English words were already Chinese. "Already is" is
        // said only by `showTranslationNoop()` — when the source really is the
        // target, or the system engine answers `nothingToTranslate` — never
        // guessed from the answer's bytes.
        //
        // The same two tests the in-place path uses, so a card and a picture
        // cannot disagree about what counts as a translation: identical words
        // long enough to be prose, or an answer still written in the script
        // that was given when another one was asked for. The second catches
        // 繁體 coming back 简体 with one character moved (2026-11-13), where
        // comparing bytes alone said it had translated.
        if case .found(let original)? = readingState {
            let target = Locale.Language(identifier: TranslationTargets.current)
            if CaptureController.sameWords(trimmed, as: original)
                || SourceLanguage.untouched(trimmed, since: original, into: target) {
                refusal = .failed
                translateNoop = false
                needsDisplay = true
                diagLog("Capture text: the answer came back untranslated")
                return
            }
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
                // The key was pressed before the area existed; this is the area
                // arriving, and the same rule the read door follows: the drag
                // that completes a chosen mode runs it.
                beginTranslation(rect)
            }
            return
        }
        // A click goes back to being a click: whatever was armed was armed for
        // a drag, and this was not one.
        longArmed = false
        readArmed = false
        // Except the translation, which is not a gesture: it says what this
        // *area* is for, and a click is one more way of naming an area. A click
        // that threw the mode away would make 「点一个窗口，再按 ✓ 翻译」 two
        // presses with nothing in between.
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
        // A colour still being aimed at, or already read, has no picture to
        // take. Every entrance to this method — Return, the check, a double
        // click — has to agree, or one of them silently photographs the whole
        // screen instead of handing over the value.
        guard !colourAiming, colourResult == nil else { return }
        // A translation waiting for an area is what this press means — the
        // whole screen is the area it gets. Every other entrance to this method
        // does the same, because a ✓ that translated while Return photographed
        // would be two meanings for one press.
        if translateArmed {
            beginTranslation(selection ?? screen.frame)
            return
        }
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
        panel = .none
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

    /// Closes whichever panel is open, and says whether it did.
    ///
    /// The controller's Escape hot key calls this too: the panel has to eat the
    /// key that would close it whether the key arrived as an event here or as a
    /// Carbon hot key from an app that is not front. One rule, one place.
    @discardableResult
    func dismissPanel() -> Bool {
        guard panelOpen else { return false }
        panel = .none
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
            // Aiming has no answer yet; agreeing with nothing would take a
            // picture of the whole screen instead.
            if colourAiming { return }
            if hasResult {
                // Agreeing with what was read. The one key that means "yes" in
                // this window, and here it does not take a picture.
                finishResult()
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
            // The grid is a way of choosing a shape; cycling them is another.
            // Left open, it would still be offering the nine while the person
            // watches the chip change one at a time.
            panel = .none
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
        case 17:                    // T — which language the words come back in
            // An entrance like `L` and `W`, and a bare key for the same reason:
            // a global `T` would take that letter from every app for the length
            // of the capture, and choosing a mode only means anything while the
            // choice is still open.
            //
            // It **walks the shortlist** rather than opening it (2026-11-13,
            // after two rounds of it opening the list): 「用 T 只能跳转到"选择
            // 语言"的按钮，但是不能去切换语言。…按 R 就可以直接跳」. The menu is
            // still there on the chip, for the case a key cannot serve — picking
            // a language that is not next in line — and the globe's click is
            // unchanged: it is a select box, and `T` is now what changes it.
            //
            // `reading == nil` is **not** in this guard, and that is deliberate:
            // after a result is up the language is exactly what a person wants
            // to change, and refusing here would make the globe dead at the one
            // moment it is needed.
            guard mode == .shot else { return }
            cycleLanguage()
        case 46:                    // M — translate, now
            // 「我们的翻译快捷键是 M 键。按 M 键的话就应该直接去做翻译……我还必须
            // 再按一下回车键，这就是多余了」(2026-11-13). Where the words land
            // already has a value in force, so there is nothing to confirm: this
            // key is the ask.
            //
            // It was arm-only for two rounds — the check was meant to be the one
            // act — and that made the ordinary case cost two presses for one
            // answer. The check is still an entrance (with an area in hand there
            // is no armed state at all, so it can only mean "capture" again),
            // but it is no longer the only one.
            //
            // `M` for the way the words come back (方式) and not `P` for the
            // place: it is the chip, not one of its two rows, and the rows are
            // chosen with the mouse.
            guard mode == .shot else { return }
            translateNow()
        case 34:                    // I — one pixel's colour, not a region
            // The same bare-key rule as `L`, `W` and `T`. `I` is what the
            // editor's eyedropper answers to, so the two doors also agree on
            // the hand that opens them.
            guard mode == .shot, reading == nil, colourResult == nil else { return }
            armColour()
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
