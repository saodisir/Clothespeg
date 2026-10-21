import AppKit
import SwiftUI

/// The window a note is written in.
///
/// The second window in this app that can take a key, and for the same reason
/// as the first: the line cannot become key at all, so there is nowhere on it
/// to put a caret. The three settings that make taking the key safe are the
/// search window's, copied rather than worked out again — they took eight
/// rounds the first time and none of that was about the note.
///
/// What it does differently is the losing of the key. The search field closes,
/// because a search is a question being asked right now and the answer belongs
/// wherever the looking is. A note is being written, and the usual reason to
/// leave this window is to go and read something — so this one finishes the
/// note and gets out of the way. Which, for a note, is the same thing as
/// saving it: nothing is written until the window is done with it anyway.
final class NoteWindow: NSPanel {
    /// Wide enough to type a sentence into, which is wider than the card it
    /// came from.
    ///
    /// The card is 210 points and an editor that narrow would wrap every line
    /// twice. So the window is anchored to the card rather than the size of
    /// it, and "over the card" means the two top left corners are in the same
    /// place — not that the two are the same rectangle. What the eye reads is
    /// the card opened out into something writable.
    static let size = NSSize(width: 320, height: 236)

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Above the line, below a menu — where the search window sits too.
        level = .statusBar
        // Every Space, full screen ones included, like the line it belongs to.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Asked to move the window by the strip at the top of the editor, which
    /// is the only part of it that drags. The deltas are the strip's own:
    /// top-down SwiftUI handed to bottom-up AppKit, which is why the y is
    /// inverted where the closure is made.
    var onMove: ((CGFloat, CGFloat) -> Void)?

    /// Hands the caret to the note. Set by the controller, which is the only
    /// thing that knows where the editor is.
    ///
    /// A closure rather than a walk down the view tree, which is what used to
    /// be here. That walk had to guess: a SwiftUI text field is an `NSTextField`
    /// with a private editor view inside it, both inside a hosting view that
    /// is neither, and "the first editable field in the tree" was the only
    /// answer available from the outside. The editor hands its view over
    /// instead, and there is nothing left to guess at.
    var onFocus: () -> Void = {}

    /// The caret goes in as soon as the window takes the key.
    ///
    /// The same arrangement as the search field, and for the same reason:
    /// asking for the caret before the activation that follows has finished
    /// is asking too early, and the key moves on its way there. So this is the
    /// later word on the subject, and it is right whenever it is the last.
    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isKeyWindow else { return }
            self.onFocus()
        }
    }
}

/// A note being written.
///
/// Held apart from the note on the line for as long as the window is open, so
/// three things fall out of the arrangement rather than having to be built:
/// the card behind the window does not change under the hand changing it,
/// nothing is written to disk on every keystroke, and Escape needs no undo
/// because there is nothing yet to undo.
///
/// One string, and the editor is one text view over it. A note is a note and
/// not a list of fields: what is written in one line belongs to the same
/// buffer as the line above it, which is the only arrangement in which a
/// selection can cross a line, ⌘Z can undo past one, and the arrow keys move
/// the way they move in every other text on the machine.
@MainActor
final class NoteDraft: ObservableObject {
    /// The card this is editing, or nil when the note is new.
    let editing: UUID?
    /// Where the card is, in the line's own space, so the window can open over
    /// it rather than beside it. Nil for a new note, which has no card.
    let anchor: CGRect?

    @Published var text: String

    /// The colour the sheet is, once the note has picked one. Nil is the
    /// paper's own colour, and the swatch in the foot of the window writes a
    /// concrete answer here. Published, because the sheet under the writing
    /// is drawn from here and the change has to be seen as it is chosen.
    @Published var tint: NoteTint?

    /// The reminder this note carries, as the picker is shaping it. Kept on
    /// the draft for the same reason the text is: nothing touches the card
    /// or the file until the note is finished, and an abandoned window
    /// leaves nothing behind.
    @Published var remindAt: Date?
    /// How the reminder comes back, or nil for one that rings once.
    @Published var remindRule: Note.RepeatRule?
    /// Whether a one-time reminder has rung and not been cleared. Carried
    /// through the edit so that opening and saving a ringing note does not
    /// quietly clear its trace — only removing the reminder does that.
    @Published var remindFired: Bool

    /// Where a reminder change goes the moment it is made, when there is a
    /// note on the line to carry it. The controller sets this as the editor
    /// opens; nil for a note that is not on the line yet, whose reminder
    /// rides to the line with the save like the rest of the note.
    ///
    /// The text stays a draft until the note is finished — that is the
    /// editor's own manner. But a reminder is a promise about a moment to
    /// come, and a promise held only in a draft is one the scheduler never
    /// hears of: the quick presets made their change, the panel showed it,
    /// and the moment arrived to silence, because the timer is only ever
    /// built from the saved note. So the reminder commits where the text
    /// does not, through the one door the scheduler watches.
    var commitLive: ((Note) -> Void)?

    /// The text view, once the editor has made one. Held weakly: the view is
    /// owned by the view tree, and this is only a way to reach it.
    weak var view: NSTextView?

    init(editing: UUID? = nil, anchor: CGRect? = nil, text: String = "",
         tint: NoteTint? = nil, remindAt: Date? = nil,
         remindRule: Note.RepeatRule? = nil, remindFired: Bool = false) {
        self.editing = editing
        self.anchor = anchor
        self.text = text
        self.tint = tint
        self.remindAt = remindAt
        self.remindRule = remindRule
        self.remindFired = remindFired
    }

    static func fresh() -> NoteDraft { NoteDraft() }

    var note: Note {
        Note(text: text, tint: tint, remindAt: remindAt,
             remindRule: remindRule, remindFired: remindFired)
    }

    // MARK: The reminder, as the picker shapes it

    /// Sets the reminder: the moment, and how it comes back.
    ///
    /// The moment lands on the minute. A reminder is read off a clock face,
    /// not off a stopwatch — "15 分钟后" pressed at 13:14:33 is a reminder
    /// for 13:29, not one for 13:29:33 that rings a third of a minute late
    /// and reads wrong on the card.
    ///
    /// A repeating one set in the past anchors at its next turn — a weekly
    /// reminder picked for a Wednesday morning that has already gone by is
    /// next Wednesday's morning, not a request the system has no answer for.
    func setReminder(at date: Date, rule: Note.RepeatRule?) {
        let minute = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
        // An unchanged reminder is not a change: re-setting what the note
        // already carries — the snap-back of a mis-typed field, a pill
        // pressed twice — must not wipe the trace of a reminder that has
        // rung.
        if remindAt == minute && remindRule == rule { return }
        remindRule = rule
        // A one-time reminder set into the past rings the moment it is
        // committed. A note that has already rung is the exception: moving
        // its time around inside the past must not ring it a second time, so
        // the fired mark stays until the reminder itself is removed.
        if !(rule == nil && minute <= Date() && remindFired) {
            remindFired = false
        }
        if let rule, minute <= Date() {
            let probe = Note(text: "", tint: nil, remindAt: minute, remindRule: rule)
            remindAt = probe.reminderOccurrence() ?? minute
        } else {
            remindAt = minute
        }
        commitLive?(note)
        ReminderScheduler.shared.authorize()
    }

    /// Re-tunes the rule on the reminder the note already carries.
    ///
    /// Switching a repeating reminder back to a single one can land on its
    /// last turn — already gone by — and a single reminder born in the past
    /// is one that rings the moment the panel closes. So a past anchor moves
    /// to the next minute: the rule changed, the moment follows it.
    func setReminder(rule: Note.RepeatRule?) {
        let anchor: Date
        if rule == nil, let at = remindAt, at <= Date() {
            anchor = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date()
        } else {
            anchor = remindAt ?? Date()
        }
        setReminder(at: anchor, rule: rule)
    }

    func remindIn(minutes: Int) {
        setReminder(at: Date().addingTimeInterval(Double(minutes) * 60), rule: nil)
    }

    func clearReminder() {
        remindAt = nil
        remindRule = nil
        remindFired = false
        commitLive?(note)
    }

    /// Puts the caret in the text.
    ///
    /// Asked more than once, because there is a gap between the editor being
    /// built and the editor being on screen, and the caret can only go in at
    /// the end of it. The waiting is bounded rather than a loop: a note whose
    /// text view never arrives is a note with no caret, not a note that spins.
    func focus(attempt: Int = 0) {
        guard let view else { return }
        guard let window = view.window else {
            guard attempt < 3 else { return }
            DispatchQueue.main.async { [weak self] in self?.focus(attempt: attempt + 1) }
            return
        }
        window.makeFirstResponder(view)
        // A text view given the caret with something already in it arrives
        // with all of it selected — right for one a person clicked into, wrong
        // for one the app just opened, where the next keystroke would replace
        // the note rather than add to it.
        let length = (view.string as NSString).length
        if length > 0, view.selectedRange() == NSRange(location: 0, length: length) {
            view.setSelectedRange(NSRange(location: length, length: 0))
        }
    }
}

/// The line the caret is on, as a range in the document, without its line
/// ending.
///
/// Read the same way by the two things that need it: the return key, deciding
/// whether to carry a list on, and the toolbar, deciding what its press lands
/// on. One reader each would be two answers to one question.
extension NSTextView {
    /// The line the caret is on, with its ending stripped.
    var caretLine: NSRange {
        let text = string as NSString
        let range = text.lineRange(for: NSRange(location: min(selectedRange().location, text.length),
                                                length: 0))
        return Self.line(withoutEnding: range, in: text)
    }

    /// A line range with any trailing newline taken off it.
    static func line(withoutEnding range: NSRange, in text: NSString) -> NSRange {
        var range = range
        while range.length > 0 {
            let last = text.substring(with: NSRange(location: range.location + range.length - 1, length: 1))
            guard last == "\n" || last == "\r" else { break }
            range.length -= 1
        }
        return range
    }
}

/// The tick box the editor draws over the characters it hides.
///
/// The box is a drawing over three characters that are still in the text —
/// `[ ]` or `[x]` — so everything about it is a question about where those
/// three are. One answer, read once, serves the three things that ask: the
/// layout manager that draws the box, the text view that answers a press on
/// it, and the display layer that hides the characters underneath. Three
/// readers of one arithmetic is how the box stays one box.
enum TickBox {
    /// The square's side, the card's own. The same box on both sides of the
    /// window is the point of the exercise.
    static let size: CGFloat = 9.5
    static let radius: CGFloat = 2.5

    /// The three characters the box is drawn over, in the document, when the
    /// line has a tick box. Any of the shapes a box is typed in — `- [ ] `,
    /// `[x] `, `[] ` — the bracket is what the box sits on, wherever in the
    /// mark it starts.
    static func bracketRange(in line: NSRange, of text: NSString) -> NSRange? {
        let content = NSTextView.line(withoutEnding: line, in: text)
        let item = NoteMark.parse(text.substring(with: content))
        guard case .todo = item.kind, let at = item.mark.firstIndex(of: "[") else { return nil }
        let offset = item.mark.distance(from: item.mark.startIndex, to: at)
        return NSRange(location: content.location + offset, length: 3)
    }

    /// The square, centred in the rectangle the three characters occupy —
    /// which is the room the mark itself was given, so the box is where the
    /// reader's eye already was.
    static func square(in rect: CGRect) -> CGRect {
        CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
    }
}

/// The layout manager that draws the tick boxes.
///
/// A subclass rather than a delegate, because what is being added is drawing
/// behind the glyphs — the one job `drawBackground` exists for — and a
/// subclass says so in one line where a delegate would say it in a protocol
/// conformance and a forwarding guard.
final class NoteLayoutManager: NSLayoutManager {
    /// The boxes, over the characters the display layer has made invisible.
    ///
    /// The whole note is walked for each redraw, the same walk the display
    /// layer does: twenty lines, parsed by the one parse everything reads.
    /// Only the boxes whose characters fall in the range being drawn are
    /// drawn, so scrolling draws only what scrolled into view.
    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard let view = firstTextView, let container = textContainers.first else { return }
        let text = view.string as NSString

        var lineStart = 0
        while lineStart < text.length {
            let ending = text.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = ending.location + ending.length
            guard let bracket = TickBox.bracketRange(in: ending, of: text),
                  bracket.location < glyphs.location + glyphs.length,
                  bracket.location + bracket.length > glyphs.location else { continue }

            let glyph = glyphRange(forCharacterRange: bracket, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyph, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            drawBox(in: rect,
                    done: text.substring(with: bracket).lowercased().contains("x"),
                    on: view)
        }
    }

    /// One box: the square the card draws, in the colours the card draws it.
    ///
    /// Unticked is a stroke. Ticked is a fill with the check picked out in
    /// the paper's own colour, so the tick reads as a hole in the ink — which
    /// is the card's arrangement exactly, and the reason the paper's colour
    /// is read off the same key the line writes.
    private func drawBox(in lineRect: CGRect, done: Bool, on view: NSTextView) {
        let box = TickBox.square(in: lineRect)
        let ink = NoteTint.nsInk(for: (view as? NoteTextView)?.tint).withAlphaComponent(0.45)

        if done {
            ink.setFill()
            NSBezierPath(roundedRect: box, xRadius: TickBox.radius, yRadius: TickBox.radius).fill()

            let check = NSBezierPath()
            check.move(to: CGPoint(x: box.minX + box.width * 0.22, y: box.midY))
            check.line(to: CGPoint(x: box.minX + box.width * 0.42, y: box.minY + box.height * 0.28))
            check.line(to: CGPoint(x: box.minX + box.width * 0.78, y: box.maxY - box.height * 0.24))
            check.lineWidth = 1.3
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor(paperColor(on: view)).setStroke()
            check.stroke()
        } else {
            let outline = NSBezierPath(roundedRect: box, xRadius: TickBox.radius, yRadius: TickBox.radius)
            outline.lineWidth = 1
            ink.setStroke()
            outline.stroke()
        }
    }

    /// The colour of the sheet under the box, which is the colour a tick is
    /// cut out of. The same answer the card's check reads, read the same way
    /// — off this note's own colour, held by the text view: a note that
    /// picked its own sheet ticks against the sheet it is on.
    private func paperColor(on view: NSTextView) -> SwiftUI.Color {
        guard let noteView = view as? NoteTextView else {
            return NoteTint.background(for: nil, in: .light)
        }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NoteTint.background(for: noteView.tint, in: dark ? .dark : .light)
    }
}

/// The text view a note is typed into, with the one extra a plain one has no
/// room for: a press that lands on a tick box ticks it.
///
/// Everything else is the text view's own business, and goes to super. A
/// press that lands anywhere but a box is a caret being placed, a selection
/// being started, a double-click choosing a word — none of which this knows
/// anything about, which is the point.
final class NoteTextView: NSTextView {
    /// The colour the sheet is — this note's own, resolved the way the view
    /// behind the text resolves it. Held here so the layout manager can read,
    /// from where it draws, the colour a tick is cut out of; the drawing and
    /// the colour are then the same reading of the same draft.
    var tint: NoteTint?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let layoutManager, let container = textContainer,
              point.x >= 0, point.y >= 0 else { return super.mouseDown(with: event) }

        let inText = NSPoint(x: point.x - textContainerOrigin.x,
                             y: point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(for: inText, in: container,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index != NSNotFound, index < (string as NSString).length else {
            return super.mouseDown(with: event)
        }

        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        if let bracket = TickBox.bracketRange(in: line, of: text) {
            let glyph = layoutManager.glyphRange(forCharacterRange: bracket, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyph, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            // A little slack round the square, for the same reason the
            // card's rows keep their targets apart: a box nine and a half
            // points across is a small thing to aim a pointer at.
            if TickBox.square(in: rect).insetBy(dx: -3, dy: -3).contains(point) {
                flip(bracket)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The flip, which is a character replacing a character — the same edit
    /// the card's press makes through `Line.tick`, arrived by its own road.
    /// Through `insertText`, so it is one undoable edit and the delegate's
    /// change bookkeeping runs as it does for a keystroke.
    private func flip(_ bracket: NSRange) {
        let current = (string as NSString).substring(with: bracket)
        insertText(current.lowercased().contains("x") ? "[ ]" : "[x]",
                   replacementRange: bracket)
    }
}

/// The note itself: one text view, and the two keys that keep a list going.
///
/// A plain `NSTextView`, which is what SwiftUI's `TextEditor` is inside and
/// what every text field on this system has been since the beginning. The
/// marks are ordinary characters in it, and they stay in the text — the note
/// is its text, and the text is what is stored.
///
/// What the eye is shown is one layer more, and it is a temporary one. The
/// same reading the card does — mark faded, done line struck through and
/// dimmed, first line heavy — is applied here as layout-manager temporary
/// attributes, which exist only at drawing time and never enter the text
/// storage. So the editor and the card agree about what a line is without the
/// note having to carry a second copy of the answer, and what is on disk is
/// still exactly what was typed.
///
/// The one thing it does not do on its own is carry a list on to the next
/// line. AppKit has no automatic list insertion — there is no such property
/// on `NSTextView` — so it comes from the delegate below, which is where every
/// Markdown editor on this platform gets it. One key, given a meaning; the
/// rest of the text view is left alone to be a text view.
struct NoteText: NSViewRepresentable {
    @ObservedObject var draft: NoteDraft

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Built by hand rather than taken from `scrollableTextView`, because
        // the box drawing and the box pressing live in subclasses: the
        // layout manager draws the square over three hidden characters, and
        // the text view answers a press on it. The assembly is the one the
        // convenience would have made, with those two substitutions.
        let storage = NSTextStorage()
        let manager = NoteLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize:
            NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)

        let view = NoteTextView(frame: .zero, textContainer: container)
        scroll.documentView = view
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]

        view.delegate = context.coordinator
        view.string = draft.text
        // Plain. The note is characters, and every one of these would quietly
        // rewrite what was typed — a straight quote made curly is a character
        // the user did not type and cannot see.
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = NoteTint.nsInk(for: draft.tint)
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.tint = draft.tint
        Self.applyDisplayAttributes(to: view)

        draft.view = view
        // The window asks for the caret as well, when it takes the key. Neither
        // of the two can know which of them happens last, so both ask and the
        // second one to arrive finds the caret already where it wants it.
        DispatchQueue.main.async { [weak draft] in draft?.focus() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NoteTextView else { return }
        // The sheet follows the swatch, which lives outside the text: the
        // view is told rather than rebuilt, and the tick's cut-out colour
        // changes with it. A redraw is asked for, since a colour on the
        // background layer is not a change in the layout.
        view.tint = draft.tint
        // The ink follows the sheet: a picked colour is light in both
        // appearances and takes the dark ink, the system colour takes the
        // system's. The display layer is rebuilt with it, since its faded
        // marks and dimmed done-lines are in that ink too.
        view.textColor = NoteTint.nsInk(for: draft.tint)
        view.needsDisplay = true
        Self.applyDisplayAttributes(to: view)
        // Only when the view is not already showing it. Writing the text back
        // on every change would take the caret out of the middle of the line
        // being typed and put it somewhere else.
        if view.string != draft.text {
            view.string = draft.text
            // Setting the string wholesale takes every temporary attribute
            // with it — the display is drawn from the storage, and the
            // storage was just replaced. So the layer is rebuilt in the same
            // breath, which is the one case PinNote's first lesson is about.
            Self.applyDisplayAttributes(to: view)
        }
    }

    /// The display layer: what the eye is shown beyond the characters.
    ///
    /// Three readings, all the card's own, so the two sides of one note are
    /// one note to look at:
    ///
    /// - a mark is faded, because it is plumbing and the words are the point;
    /// - a done line is struck through and dimmed, which is how "done" reads
    ///   everywhere else, and the strike is drawn in the dim colour so the
    ///   line reads as one thing rather than as ink under a rule;
    /// - the first line, when it is prose, is set in the heavier face, and it
    ///   is the title because it is first.
    ///
    /// Temporary attributes only: `removeTemporaryAttribute` clears each of
    /// the four keys across the whole text first, so a line that stops being
    /// done stops looking done the next time this runs. The reading is the
    /// same parse the card and the return key use — one note, one parse.
    ///
    /// Reading `layoutManager` moves the text view to TextKit 1, once, for
    /// good. That is the price and it is a small one: this is a note of
    /// twenty lines, not a book, and TextKit 1 has laid out every note in
    /// every app for thirty years.
    static func applyDisplayAttributes(to view: NSTextView) {
        guard let layoutManager = view.layoutManager else { return }
        let ink = NoteTint.nsInk(for: (view as? NoteTextView)?.tint)
        let text = view.string as NSString
        let whole = NSRange(location: 0, length: text.length)
        for key: NSAttributedString.Key in [.font, .foregroundColor,
                                            .strikethroughStyle, .strikethroughColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: whole)
        }

        var lineStart = 0
        while lineStart < text.length {
            let ending = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = NSTextView.line(withoutEnding: ending, in: text)
            defer { lineStart = ending.location + ending.length }

            let item = NoteMark.parse(text.substring(with: line))
            if !item.mark.isEmpty {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: ink.withAlphaComponent(0.32),
                    forCharacterRange: NSRange(location: line.location, length: item.mark.count))
            }
            if item.isDone {
                let dim = ink.withAlphaComponent(0.45)
                layoutManager.addTemporaryAttributes(
                    [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                     .strikethroughColor: dim,
                     .foregroundColor: dim],
                    forCharacterRange: line)
            }
            // The three characters of a tick box go invisible: the layout
            // manager draws the real box over the room they keep, which is
            // the room the reader's eye was already at. They stay in the
            // text — still selectable, still in what is saved — and the
            // press that ticks the box replaces them, which is how the
            // drawing and the text cannot fall out of step.
            if let bracket = TickBox.bracketRange(in: ending, of: text) {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: NSColor.clear,
                    forCharacterRange: bracket)
            }

            Self.applyInlineAttributes(on: text.substring(with: line),
                                       at: line, to: layoutManager, ink: ink)
        }
    }

    // MARK: Inline markdown

    /// Inline markdown, shown as what it means and kept as what it is.
    ///
    /// The words between the marks take the face; the marks themselves stay
    /// where they are, faded the way every other mark in this editor is
    /// faded — plumbing, not content. Nothing is hidden here, and the reason
    /// is the caret: a delimiter you cannot see is a delimiter you cannot
    /// put the caret beside to delete, and markup that cannot be undone from
    /// the keyboard is markup that owns the text.
    ///
    /// The spans are the one parse the card reads too.
    private static func applyInlineAttributes(on line: String, at range: NSRange, to layoutManager: NSLayoutManager, ink: NSColor) {
        func inDocument(_ r: NSRange) -> NSRange {
            NSRange(location: range.location + r.location, length: r.length)
        }
        func fade(_ r: NSRange) {
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: ink.withAlphaComponent(0.32),
                forCharacterRange: inDocument(r))
        }

        for span in NoteInline.spans(in: line) {
            layoutManager.addTemporaryAttribute(
                .font, value: NSFont.systemFont(ofSize: 13, weight: .bold),
                forCharacterRange: inDocument(span.inner))
            for delimiter in span.delimiters {
                fade(delimiter)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(draft: draft) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let draft: NoteDraft

        init(draft: NoteDraft) { self.draft = draft }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            draft.text = view.string
            // The characters just typed arrived with no display on them, and
            // the line they are on may have changed kind — a mark half-typed
            // is prose until it is not. The layer is read off the whole note
            // every time, which is a walk over twenty lines and no more.
            NoteText.applyDisplayAttributes(to: view)
        }

        /// Enter does one thing when the line is a list line: it carries the
        /// list on. Everything else is left to the text view.
        ///
        /// Returning false is what leaves it alone — the delegate answers
        /// "did you deal with this", and a key this does not recognise has to
        /// be handed back or the text view would stop inserting newlines.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return continueList(in: view)
        }

        private func continueList(in view: NSTextView) -> Bool {
            let text = view.string as NSString
            let caret = view.selectedRange()
            let line = view.caretLine

            // Only when the caret is at the end of what was written. Enter in
            // the middle of a line is somebody editing a line rather than
            // adding one, and carrying a mark into the middle of a sentence
            // would leave it standing in front of half of it.
            guard caret.location == line.location + line.length else { return false }

            let item = NoteMark.parse(text.substring(with: line))
            // Nothing to carry on: a newline is a newline.
            guard item.hasMarker else { return false }

            // Enter on a mark with nothing after it ends the list, which is
            // how every list anybody has typed behaves — and without it a list
            // can only be abandoned, never finished. The mark goes and the
            // line becomes the blank one under the list.
            guard !item.isBlank else {
                view.setSelectedRange(line)
                insert(view, "")
                return true
            }

            insert(view, "\n" + NoteMark.continued(item))
            return true
        }

        /// Puts a string in where the selection is, and keeps the draft in
        /// step.
        ///
        /// Through `insertText` rather than the text storage, so the whole
        /// thing is one undoable edit and the text view's own bookkeeping —
        /// the caret, the invalidated layout — comes along for the ride.
        private func insert(_ view: NSTextView, _ string: String) {
            view.insertText(string, replacementRange: view.selectedRange())
            draft.text = view.string
        }
    }
}

/// The toolbar's three marks, and the one press each of them means.
///
/// They are characters, not attributes — the same characters the return key
/// reads and the card parses, so the toolbar, the editor and the card cannot
/// disagree about what a line is: there is only the text, and all three read
/// it. That is also why there is nothing here to store: the mark is in the
/// note because the note is its text.
extension NoteEditor {
    /// The three text faces, each a wrap around what is selected.
    ///
    /// The face is characters the same way a mark is: `**` is bold because
    /// the display layer reads it as bold, not because an attribute was set.
    /// That is the whole distance between this and a rich-text toolbar — one
    /// stores what the text says, the other would store a second copy of it.
    ///
    /// Bold is the only one, and not because the reader cannot read the
    /// others: a note with `*this*` or `` `this` `` in it still draws them
    /// both here and on the card. It is because the buttons were the only
    /// place the two were taught, and two buttons for shapes that read as
    /// little more than a smudge at thirteen points were teaching a
    /// distinction nobody could see.
    enum Face: String, CaseIterable, Identifiable {
        case bold

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .bold: "bold"
            }
        }

        var delimiter: String {
            switch self {
            case .bold: "**"
            }
        }

        var help: String {
            switch self {
            case .bold: L("Bold")
            }
        }
    }

    enum Mark: String, CaseIterable, Identifiable {
        case bullet, number, box

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .bullet: "list.bullet"
            case .number: "list.number"
            case .box: "checklist"
            }
        }

        var help: String {
            switch self {
            case .bullet: L("Bullet list")
            case .number: L("Numbered list")
            case .box: L("Tick box")
            }
        }

        /// The kind of line this mark makes, for the toggle test.
        var kind: NoteItem.Kind {
            switch self {
            case .bullet: .bullet
            case .number: .numbered
            case .box: .todo(done: false)
            }
        }
    }
}

extension NoteDraft {
    /// The toolbar's press: the mark named, put on the line the caret is on —
    /// or taken off it, when that line already has it.
    ///
    /// Through `insertText` rather than the text storage, so the change is one
    /// undoable edit like any keystroke, and through the view rather than the
    /// draft for the same reason the typing is: the view is where the caret
    /// and the layout live, and the draft only reads what results.
    func toggleMark(_ mark: NoteEditor.Mark) {
        guard let view else { return }
        let text = view.string as NSString
        let line = view.caretLine
        let parsed = NoteMark.parse(text.substring(with: line))

        // The mark this line will carry. A numbered line continues the list it
        // is in — the number is read off the line above, and a line with
        // nothing numbered above it starts the list — which is what the
        // return key does and why the two should agree.
        let markString: String
        switch mark {
        case .bullet: markString = "- "
        case .box: markString = "- [ ] "
        case .number:
            if line.location > 0 {
                let above = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
                let trimmed = NSTextView.line(withoutEnding: above, in: text)
                let previous = NoteMark.parse(text.substring(with: trimmed))
                markString = previous.isNumbered ? NoteMark.continued(previous) : "1. "
            } else {
                markString = "1. "
            }
        }

        // The same mark again is the mark coming off. Every list button on
        // every editor toggles, and one that only ever adds leaves no way
        // back to prose but deleting the mark by hand.
        let replacement = parsed.kind == mark.kind
            ? parsed.text
            : markString + parsed.text

        view.insertText(replacement, replacementRange: line)
        self.text = view.string
        // The press spent the caret on the button. It belongs back in the
        // note, at the line that was just marked.
        focus()
    }

    /// The face press: the delimiter wrapped round what is selected.
    ///
    /// Three answers, one per state the selection can be in. A selection
    /// gets the wrap; a selection already wrapped loses it, which is the
    /// same toggle every face button on every editor answers with; and no
    /// selection gets an empty pair with the caret inside, because the words
    /// come after the decision to set them in bold. Through `insertText`
    /// each time, so every one of them is one undoable edit.
    func wrapSelection(_ delimiter: String) {
        guard let view else { return }
        let text = view.string as NSString
        let selected = view.selectedRange()

        if selected.length > 0 {
            let content = text.substring(with: selected)
            let wrapped = content.hasPrefix(delimiter)
                && content.hasSuffix(delimiter)
                && content.count >= delimiter.count * 2
            if wrapped {
                let inner = (content as NSString).substring(
                    with: NSRange(location: delimiter.count,
                                  length: content.count - delimiter.count * 2))
                view.insertText(inner, replacementRange: selected)
            } else {
                view.insertText(delimiter + content + delimiter,
                                replacementRange: selected)
                // The words stay selected, one step out from the middle, so
                // a second press unwraps rather than nests.
                view.setSelectedRange(NSRange(location: selected.location + delimiter.count,
                                              length: selected.length))
            }
        } else {
            view.insertText(delimiter + delimiter, replacementRange: selected)
            view.setSelectedRange(NSRange(location: selected.location + delimiter.count, length: 0))
        }
        self.text = view.string
    }
}

/// What the editor draws: the note, and the one place that says how it works.
struct NoteEditor: View {
    @ObservedObject var draft: NoteDraft
    /// Finished with: the note to keep, or nil when it was thrown away.
    var onFinish: (Note?) -> Void

    @Environment(\.colorScheme) private var scheme
    /// Whether the colour swatches are out. Opened from the circle in the
    /// foot of the window, closed by a pick, a second press or a click
    /// anywhere else.
    @State private var showingTints = false
    /// Whether the reminder picker is out, from the bell beside the circle.
    /// Same manners as the swatches: one press opens, one closes, a click
    /// outside closes.
    @State private var showingReminder = false
    /// The last translation the strip's drag reported, so the window moves
    /// by the step between events rather than by the whole distance from
    /// where the finger went down.
    @State private var dragTranslation: CGSize?

    /// Hands a step of the strip's drag to the window, which is the thing
    /// being dragged. Found rather than injected: there is one editor on
    /// screen at a time and one window behind it, and the y step is
    /// inverted here because the strip measures top-down and the window
    /// lives bottom-up.
    private func moveWindow(_ dx: CGFloat, _ dy: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0 is NoteWindow }) else { return }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY - dy))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The strip. The one part of the window that drags it, and the
            // cross that ends the note — ending it, not throwing it away:
            // the cross saves what is written, because a close that loses
            // the words is a close nobody dares to press. Nothing else
            // closes the window; a click outside leaves the writing alone.
            //
            // As deep as the foot of the window is: the strip with the cross
            // and the strip with the swatch and the save are the window's
            // two edges, and edges that were different depths would read as
            // two different kinds of thing. The same measure both ends.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button { onFinish(draft.note.tidied) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.55))
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Save"))
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if let last = dragTranslation {
                        moveWindow(value.translation.width - last.width,
                                   value.translation.height - last.height)
                    }
                    dragTranslation = value.translation
                }
                .onEnded { _ in dragTranslation = nil })
            .zIndex(2)

            // The sheet under the writing, and the writing on it. The text
            // view draws no background of its own, so what is under it is
            // what shows through — the same arrangement as the card, where
            // the ink sits on the paper and the paper is the ground.
            ZStack {
                PaperSheet(tint: draft.tint)
                NoteText(draft: draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)

            HStack(spacing: 6) {
                // The three faces, each a wrap round what is selected — the
                // same characters the display layer reads, written by the
                // press instead of typed by the hand. A hint once stood here
                // saying what to type; the buttons say it better, by doing
                // it.
                ForEach(NoteEditor.Face.allCases) { face in
                    Button { draft.wrapSelection(face.delimiter) } label: {
                        Image(systemName: face.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.7))
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(face.help)
                }

                // The three marks, one press each.
                ForEach(NoteEditor.Mark.allCases) { mark in
                    Button { draft.toggleMark(mark) } label: {
                        Image(systemName: mark.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.7))
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(mark.help)
                }
                Spacer(minLength: 0)
                reminderPicker
                tintPicker
                Button { onFinish(draft.note.tidied) } label: {
                    Text(L("Save"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .glassFrame(capsule: true)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: NoteWindow.size.width, height: NoteWindow.size.height)
        // The sheet ends where the glass does. The text area reaches the top
        // of the window, and a sheet with square corners sitting in a frame
        // with rounded ones would poke out past the glass at the top two.
        .clipShape(RoundedRectangle(cornerRadius: Frame.radius, style: .continuous))
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Frame.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
                .stroke(Edge.gradient, lineWidth: 0.75)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
                .stroke(Edge.rim, lineWidth: 0.5).padding(-0.5)
        )
        .onExitCommand { onFinish(nil) }
    }

    /// The reminder, picked from a panel the bell in the foot of the window
    /// opens. Same door as the swatches — a system menu redraws its own rows,
    /// and this one has three sections of its own to draw.
    ///
    /// The bell says what it carries: a quiet outline for no reminder, the
    /// clay filled one for a note that will ring. A ringing note keeps the
    /// filled bell; its card says so in its own words.
    private var reminderPicker: some View {
        Button {
            showingReminder.toggle()
        } label: {
            Group {
                if draft.remindAt != nil {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(CDS.clay)
                } else {
                    Image(systemName: "bell")
                        .foregroundStyle(.primary.opacity(0.7))
                }
            }
            .font(.system(size: 10, weight: .medium))
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingReminder, arrowEdge: .bottom) {
            ReminderPicker(draft: draft)
        }
        .help(L("Reminder"))
    }

    /// The colour the sheet is, picked from swatches that are the colours
    /// themselves.
    ///
    /// A menu of names was tried twice and was twice the wrong answer — the
    /// first time it never arrived on screen, the second it arrived without
    /// the circles that were the whole point — and the reason is that a
    /// system menu draws its own rows. So the swatches are drawn here, where
    /// nothing can redraw them: a row of circles that *are* the colours, the
    /// chosen one ringed, over the foot of the window they colour.
    private var tintPicker: some View {
        Button {
            showingTints.toggle()
        } label: {
            Circle()
                .fill(NoteTint.background(for: draft.tint, in: scheme))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.75))
                .frame(width: 12, height: 12)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingTints, arrowEdge: .bottom) {
            TintSwatches(selection: $draft.tint, scheme: scheme)
        }
        .help(L("Tint"))
    }
}

/// The row of colours the swatch opens: the circles themselves, the chosen
/// one ringed. The system colour first — the one choice that follows the
/// appearance rather than holding to what was picked.
private struct TintSwatches: View {
    @Binding var selection: NoteTint?
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 8) {
            swatch(nil, name: L("System colour"))
                .padding(.trailing, 8)
            ForEach(NoteTint.allCases) { tint in
                swatch(tint, name: tint.label)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func swatch(_ tint: NoteTint?, name: String) -> some View {
        let chosen = selection == tint
        return Button {
            selection = tint
        } label: {
            Group {
                if tint == nil {
                    // The system colour wears a face none of the palette
                    // shares: half light, half dark, cut corner to corner.
                    // It is the only choice that changes with the
                    // appearance, so it is the only circle drawn as both at
                    // once — a white circle and a black circle are the same
                    // circle on the day the appearance flips, and neither
                    // says "I am the one that follows". The extra gap to its
                    // right sets it apart from the palette it is not part
                    // of.
                    Circle()
                        .fill(LinearGradient(stops: [
                            .init(color: Color(white: 0.97), location: 0.499),
                            .init(color: Color(white: 0.14), location: 0.501),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    Circle()
                        .fill(NoteTint.background(for: tint, in: scheme))
                }
            }
            .overlay(
                Circle().strokeBorder(chosen ? Color.accentColor : Color.primary.opacity(0.25),
                                      lineWidth: chosen ? 2 : 0.75)
            )
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

/// The panel the bell opens: what the note's reminder is, and the ways to
/// shape it.
///
/// Two speeds on purpose. A quick preset applies the moment it is pressed —
/// the common reminder is "in a while", and the press *is* the decision, so
/// it lands and the panel closes. The custom side keeps its own copy of the
/// answer and changes nothing until 确定 says so: a date half-picked must
/// not quietly become a reminder, and 确定 and 移除 sit side by side so the
/// two endings — keep this, drop this — read as the pair they are.
private struct ReminderPicker: View {
    @ObservedObject var draft: NoteDraft
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    /// The panel is live: a change lands on the note the moment it is made,
    /// and 确定 only closes. The button stays because "done here" deserves
    /// a word, not because anything was waiting for it.
    @State private var timeText: String
    @State private var showingCalendar = false
    @FocusState private var timeFocused: Bool

    init(draft: NoteDraft) {
        self.draft = draft
        _timeText = State(initialValue: Self.timeString(draft.remindAt ?? Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // One line, two answers: what the note carries on the left, what
            // 确定 would store on the right. Reading them side by side is
            // how a half-made choice never slips past 确定 unnoticed.
            HStack(alignment: .firstTextBaseline) {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(draft.remindFired ? CDS.clay
                        : (hasReminder ? Color.primary : Color.secondary))
                Spacer(minLength: 8)
                Text(preview)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CDS.clay)
                    .lineLimit(1)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)

            Text(L("Quick"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                pill(L("In 15 minutes")) { applyNow { draft.remindIn(minutes: 15) } }
                pill(L("In 30 minutes")) { applyNow { draft.remindIn(minutes: 30) } }
                pill(L("In 1 hour")) { applyNow { draft.remindIn(minutes: 60) } }
            }

            Text(L("Custom"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // Day and minute in one row, and nothing always on show. The
            // always-out calendar was the panel's whole height spent on a
            // question asked twice a month; now the date is a field that
            // opens its calendar on a click, the time is a text field with
            // a minute stepper beside it, and the row reads like the two
            // small answers it is.
            HStack(spacing: 6) {
                dateField
                timeField
            }

            Text(L("Repeat"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // The repeat pills are live like everything else, and they stay
            // open: the point of a rule is the 下次 it produces, and closing
            // here would hide the very answer the top line was built to show.
            HStack(spacing: 6) {
                pill(L("No repeat"), selected: draft.remindRule == nil) {
                    draft.setReminder(rule: nil)
                }
                pill(L("Every day"), selected: draft.remindRule == .daily) {
                    draft.setReminder(rule: .daily)
                }
                pill(L("Every week"), selected: draft.remindRule == .weekly) {
                    draft.setReminder(rule: .weekly)
                }
                pill(L("Every month"), selected: draft.remindRule == .monthly) {
                    draft.setReminder(rule: .monthly)
                }
            }

            // The pair. 移除 drops the reminder whole and sits on the left;
            // 确定 keeps the work and sits on the right, where macOS puts the
            // confirming button. Equal in size because they are equal in rank
            // — the two endings this panel offers — and different in weight so
            // the eye knows which one keeps the work.
            HStack(spacing: 8) {
                Button {
                    draft.clearReminder()
                    dismiss()
                } label: {
                    Label(L("Remove"), systemImage: "bell.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hasReminder ? Color.primary : Color.primary.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.04)))
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!hasReminder)

                Button {
                    commitTime()
                    dismiss()
                } label: {
                    Text(L("Done"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CDS.label(onClayIn: scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(CDS.clay))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        // The field reads the note, not the other way only: a change made
        // anywhere else in the panel — the calendar, a pill — says itself
        // back into the time field, so one panel never shows two answers.
        .onChange(of: draft.remindAt) { _, _ in
            guard !timeFocused else { return }
            timeText = Self.timeString(draft.remindAt ?? Date())
        }
        .padding(12)
        .frame(width: 272)
    }

    /// The day, as a field. The calendar is not always out — it opens over
    /// this on a click, carries its own day stepper, and goes away.
    private var dateField: some View {
        Button {
            showingCalendar.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(Self.dateText(custom.wrappedValue))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary)
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            DatePicker(selection: custom, in: Self.floor(for: draft.remindAt)...,
                       displayedComponents: [.date]) { }
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
        }
    }

    /// The minute, as a field: typed, or stepped — five minutes a click,
    /// because a reminder set to the minute is a coincidence, not a plan.
    private var timeField: some View {
        HStack(spacing: 3) {
            TextField("HH:mm", text: $timeText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .frame(width: 58)
                .focused($timeFocused)
                .onSubmit { commitTime() }
                .onChange(of: timeFocused) { _, focused in
                    if !focused { commitTime() }
                }
                // The typed time is taken the instant it parses. Waiting
                // for the field to give up its focus was a wait the panel
                // did not always grant — 确定 closed it with the field
                // still holding the typed time, and the change was left in
                // the field, not on the note. A keystroke that says a whole
                // time is a whole answer, and it lands at once; one that
                // does not parse yet is a half-typed word, and waits.
                // Only the user's own typing commits. The field is written
                // from the program too — the sync when the note's reminder
                // changes, the revert on blur — and those echoes must not be
                // read back as answers: 移除 synced "now" into the field,
                // the echo re-wrote it as a single born overdue, and
                // reconcile rang it at once (16:07:45, twice). The user can
                // only type while focused, so focus is the line between
                // input and echo.
                .onChange(of: timeText) { _, _ in
                    guard timeFocused else { return }
                    commitIfValid()
                }
            VStack(spacing: 1) {
                nudgeButton("chevron.up", 5)
                nudgeButton("chevron.down", -5)
            }
        }
    }

    /// One end of the minute stepper, over the time field.
    private func nudgeButton(_ symbol: String, _ minutes: Int) -> some View {
        Button { nudge(minutes) } label: {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.6))
                .frame(width: 16, height: 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Steps the minute, and says the answer back into the field.
    private func nudge(_ minutes: Int) {
        commitTime()
        let base = draft.remindAt ?? Date()
        draft.setReminder(
            at: Calendar.current.date(byAdding: .minute, value: minutes, to: base) ?? base,
            rule: draft.remindRule)
    }

    /// What the left of the top line says the note carries.
    private var statusText: String {
        if draft.remindFired { return L("Reminder arrived") }
        if let summary { return summary }
        return L("Not set")
    }

    /// The custom moment: what the note carries, or now while there is
    /// nothing yet. Writing into it sets the reminder with the rule it
    /// already has — the panel is live, so the pick is the write.
    private var custom: Binding<Date> {
        Binding(get: { draft.remindAt ?? Date() },
                set: { draft.setReminder(at: $0, rule: draft.remindRule) })
    }

    /// A preset press lands and the panel closes: the press is the whole
    /// conversation a preset needs.
    private func applyNow(_ action: () -> Void) {
        action()
        dismiss()
    }

    /// The field's unfinished typing, put back to what the note says. The
    /// writing itself happens per keystroke — a whole time lands the moment
    /// it is typed — so blur has nothing left to commit, and that is the
    /// point: a field that cannot write on its way out cannot resurrect a
    /// reminder the user just removed (16:07:45: 移除 closed the panel, blur
    /// re-wrote "now" as a past single, and reconcile rang it at once).
    private func commitTime() {
        guard committedTime == nil else { return }
        timeText = Self.timeString(draft.remindAt ?? Date())
    }

    /// The typed time, taken while it is still being typed: a whole time
    /// lands at once, a half-typed one waits. Used on every keystroke, so
    /// no way of closing the panel — 确定, a click outside, anything — can
    /// leave a finished answer behind in the field.
    private func commitIfValid() {
        guard let time = committedTime else { return }
        draft.setReminder(at: time, rule: draft.remindRule)
    }

    var hasReminder: Bool { draft.remindAt != nil }

    /// What the right of the top line says: the *next* moment this reminder
    /// means anything, full date and all. "每天 09:00" on the left is the
    /// rule; "下次 10月20日 09:00" here is when that rule next lands — the
    /// 下次 is what keeps the two columns from saying one thing twice.
    private var preview: String {
        guard let next = draft.note.reminderOccurrence() else { return "" }
        return "\(L("Next")) \(Note.reminderSummary(at: next, rule: nil) ?? "")"
    }

    /// The typed time, as a moment on the set day — or nil while the field
    /// holds something the clock cannot say.
    private var committedTime: Date? {
        let parts = timeText.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            return nil
        }
        return Calendar.current.date(
            bySettingHour: parts[0], minute: parts[1], second: 0, of: draft.remindAt ?? Date())
    }

    /// The field's own spelling of a moment: 24-hour, zero-padded — a time
    /// a text field can take back without a second reader.
    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The day field's spelling of a day: the calendar's own words —
    /// "10月19日", "Oct 19" — compact enough to sit beside the time.
    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    /// The picker's floor: an anchor already behind — a repeating note's
    /// normal state — stays reachable, but a note with nothing yet cannot
    /// be given a moment in the past. The first test proved why: the
    /// picker's untouched answer is "now", and a stray touch on it wrote a
    /// reminder that was born overdue, and overdue meant silent.
    static func floor(for anchor: Date?) -> Date {
        min(anchor ?? Date(), Date())
    }

    /// What the header says the note carries, in the calendar's own words.
    private var summary: String? {
        Note.reminderSummary(at: draft.remindAt, rule: draft.remindRule)
    }

    /// The panel's quiet pill, clay when it is the answer the panel is
    /// carrying.
    private func pill(_ title: String, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? CDS.label(onClayIn: scheme) : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(selected ? CDS.clay : Color.primary.opacity(0.04))
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.primary.opacity(selected ? 0 : 0.14), lineWidth: 0.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The window the note is written in, and everything about when it is there.
///
/// A singleton for the same reason the search controller is one: there is one
/// window, three or four places that can ask for it, and a window ordered in
/// by one of them and out by another is a window that is sometimes neither.
@MainActor
final class NoteController {
    static let shared = NoteController()

    private(set) var window: NoteWindow?
    private var host: NSView?
    private var draft: NoteDraft?

    /// The line, so a finished note has somewhere to go. Handed over at launch
    /// the way the settings window is given it, rather than threaded through
    /// the view tree.
    weak var line: Line?

    private init() {}

    /// Escape ends the note, taken by a monitor rather than left to the field.
    ///
    /// The caret is in a text view with something in it, and on a view with
    /// something in it Escape is its own `cancelOperation` — stop editing this
    /// line, not leave — so the press would be spent on the text view and the
    /// window would sit there with nothing left to give it. The monitor sees
    /// the key before the view does and hands back nil, which is what makes
    /// one Escape always mean one thing: out of the note, and not out of the
    /// line being typed.
    ///
    /// The same arrangement, and the same reason, as the search field's. It is
    /// installed once and lives as long as this controller rather than being
    /// added and removed with each window: it does nothing at all while no
    /// note is open, and a monitor added per window is one removed per window
    /// and eventually removed twice.
    private var escapeMonitor: Any?

    /// The same one-time installation as the escape monitor: added once,
    /// alive as long as the controller, silent while no note is open.
    private var ringObserver: Any?

    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            guard event.keyCode == 53 else { return event }
            let ends: Bool = MainActor.assumeIsolated {
                guard let self, self.isOpen else { return false }
                self.finish(nil, editing: self.draft?.editing)
                return true
            }
            return ends ? nil : event
        }
    }

    /// A reminder that rings while its own editor is open must be heard by
    /// the draft too. The line marks its note as rung; the draft still says
    /// "not yet" — and a save from that draft would wipe the mark, and the
    /// next reconcile would meet a one-time reminder past its moment and
    /// undelivered, and ring it a second time. So the ring is echoed here,
    /// with the line's own rule: only a single one carries the mark.
    private func watchRings() {
        guard ringObserver == nil else { return }
        ringObserver = NotificationCenter.default.addObserver(
            forName: ReminderScheduler.firedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let id = notification.userInfo?["id"] as? UUID else { return }
            MainActor.assumeIsolated {
                guard let self, let draft = self.draft, draft.editing == id,
                      draft.remindRule == nil else { return }
                draft.remindFired = true
            }
        }
    }

    /// A note that is not on the line yet. No card, so nothing to open over:
    /// the window arrives where the pointer already is.
    func beginNew() {
        present(NoteDraft.fresh())
    }

    /// The note that is already hanging, opened over itself.
    func edit(_ item: Pegged) {
        guard case .note(let note) = item.payload else { return }
        // The ringing card's light goes out here: the person it rang for is
        // the person opening it. The fired mark on a one-time reminder stays
        // until the reminder itself is removed.
        line?.clearNoteHighlight(item.id)
        present(NoteDraft(editing: item.id,
                          anchor: line?.hitRects[item.id],
                          text: note.text,
                          tint: note.tint,
                          remindAt: note.remindAt,
                          remindRule: note.remindRule,
                          remindFired: note.remindFired))
    }

    var isOpen: Bool { window?.isVisible ?? false }

    private func present(_ draft: NoteDraft) {
        close()

        let host = NSHostingView(rootView: NoteEditor(draft: draft) { [weak self] note in
            self?.finish(note, editing: draft.editing)
        })

        // The reminder commits live, for a note that is already on the line:
        // the scheduler builds its timers from the saved note, and a reminder
        // that lives only in the draft is one the moment comes to and passes
        // in silence. The editing id is taken out up front, so the closure
        // holds no draft — a draft holding its own commit is a pair that
        // outlives the window.
        let editing = draft.editing
        draft.commitLive = { [weak self] note in
            guard let self, let editing else { return }
            self.line?.rewrite(editing, to: note.tidied)
        }
        host.sizingOptions = []
        let window = NoteWindow(content: host)
        window.setContentSize(NoteWindow.size)

        self.host = host
        self.draft = draft
        self.window = window

        window.onFocus = { [weak self] in self?.draft?.focus() }
        // The strip at the top of the editor drags; the y is inverted because
        // the strip measures top-down and the window lives bottom-up.
        window.onMove = { [weak self] dx, dy in
            guard let self, let window = self.window else { return }
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY - dy))
        }

        // Placed before it comes forward. A window ordered in at the wrong
        // size or in the wrong place is on screen while it moves, and a card
        // that opens out and then slides somewhere else reads as a mistake.
        window.setFrameOrigin(origin(for: draft.anchor))
        window.makeKeyAndOrderFront(nil)
        watchEscape()
        watchRings()

        // The caret is asked for once more after the activation settles. The
        // window does this for itself when it takes the key and that is often
        // enough, but the key can be given back on the way there.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            window.onFocus()
        }
    }

    /// Done with: the note goes on the line, or the card it came from takes
    /// the new version, or nothing happens at all.
    private func finish(_ note: Note?, editing: UUID?) {
        close()
        // Escape, or a window abandoned in a way this does not handle.
        guard let note else { return }
        let tidied = note.tidied
        // A note of blank lines is not a note. Nothing is hung and nothing is
        // changed: emptying a note is not how a note is thrown away — the
        // cross on the card is, and it says so before it does it.
        guard !tidied.isBlank else { return }
        if let editing {
            line?.rewrite(editing, to: tidied)
        } else {
            line?.hang(note: tidied)
        }
    }

    func close() {
        // Cleared first. Ordering the window out while a handler is still
        // attached would let the ending of the note read the ending of the
        // window.
        window?.onFocus = {}
        window?.onMove = nil
        window?.orderOut(nil)
        window = nil
        host = nil
        draft = nil
    }

    /// Where the window goes.
    ///
    /// Over the card when there is one. The line's space has its origin at the
    /// top left the way SwiftUI's does and AppKit's is at the bottom left, so
    /// the height comes back off — the card's top left corner in screen
    /// coordinates, and the window's top left put there.
    private func origin(for anchor: CGRect?) -> NSPoint {
        let size = NoteWindow.size
        guard let anchor, anchor != .zero, let panel = line?.panelFrame else {
            return clamped(centredOrigin(size), size: size)
        }
        let corner = NSPoint(x: panel.minX + anchor.minX,
                             y: panel.maxY - anchor.minY)
        return clamped(NSPoint(x: corner.x, y: corner.y - size.height), size: size)
    }

    private func centredOrigin(_ size: NSSize) -> NSPoint {
        let screen = LinePanel.screenUnderPointer() ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }

    /// Keeps the window on the screen it was asked for.
    ///
    /// A card on the far left of the screen would otherwise open a window
    /// half off the edge, and part of a note editor that is off the edge is
    /// part of the note that cannot be typed into.
    private func clamped(_ point: NSPoint, size: NSSize) -> NSPoint {
        let screen = LinePanel.screenUnderPointer() ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return point }
        let x = min(max(point.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        let y = min(max(point.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return NSPoint(x: x, y: y)
    }
}
