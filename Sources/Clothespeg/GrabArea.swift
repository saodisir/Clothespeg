import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Press and hold opens Markup, the corner cross discards. A double click
/// opens the card, and a single click does nothing — copying on the way past
/// was tried and taken off: a press this easy to make by accident should not
/// put anything on the pasteboard.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line
    /// The note's wheel position, shared with the card that draws the rows.
    /// Constant zero for everything that is not a note.
    var noteScroll: Binding<CGFloat> = .constant(0)

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    /// Where the zoom opens from: under the middle of this card, in screen
    /// coordinates, which is what the zoom window places itself against.
    private var zoomAnchor: NSPoint {
        guard let rect = line.hitRects[item.id] else { return .zero }
        let panel = line.panelFrame
        return NSPoint(x: panel.minX + rect.midX, y: panel.minY + rect.minY)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        // A note counts as text here, and for the same reason: there is no
        // file behind it. This is what decides whether the menu may offer to
        // open the card, annotate it, show it in the Finder or throw it in
        // the Trash — and a note has no file to annotate and none to throw
        // away, so a menu offering those would be four items of which one
        // does nothing at all and three do something else.
        let isText = item.isText || item.payload.isNote
        let isNote = item.payload.isNote
        view.payload = item.payload
        view.url = item.url
        view.dragImage = item.thumb
        // Where the squares are on a note, so a press on one ticks that line
        // instead of copying the card. Empty for everything else, which is
        // what keeps this from being a second code path for every card: a
        // card with no rows in it has no second meaning for a press.
        //
        // Every row is here, the ones below the fold included — the paper is
        // scrolled, not shortened, so a square below the window still ticks
        // when it is scrolled into view.
        let arrangement = item.payload.note.map { NoteCardLayout.arrange($0) }
        view.noteRows = arrangement?.rows ?? []
        // What the wheel has to work with, and where the wheel has got to so
        // far. A note edited shorter has its position clamped here rather
        // than being left pointing past the end of its own paper.
        view.noteScrollMax = arrangement.map { max(0, $0.fullHeight - $0.height) } ?? 0
        view.noteScrollOffset = min(noteScroll.wrappedValue, view.noteScrollMax)
        view.onNoteScroll = { noteScroll.wrappedValue = $0 }
        view.onTick = { row in line.tick(id, row: row) }
        // A ringing card wears its 知道了 along the caption's right end, and
        // the press region sits under the drawing. A repeated reminder never
        // carries the fired mark, but both kinds ring, so the test is the
        // highlight itself rather than the mark.
        if line.highlightedNoteID == id, let arrangement {
            view.ackRect = CGRect(
                x: NoteCardLayout.width * 0.45,
                y: arrangement.height - NoteCardLayout.bottomPad - NoteCardLayout.captionHeight,
                width: NoteCardLayout.width * 0.55 - NoteCardLayout.sidePad,
                height: NoteCardLayout.captionHeight)
            view.onAcknowledge = {
                diagLog("Reminder acknowledged: \(id)")
                line.clearNoteHighlight(id)
            }
        }
        // The two decks answer one set of gestures, whatever they hold (the
        // 2026-10-17 unification): a press copies, a double click pastes to
        // the app in front, a long press opens the editor — the system
        // Markup for a thing with a file, this app's note editor for a thing
        // that lives nowhere else. The corner mark is the one deliberate
        // difference: a magnifier over text you cannot edit is the wrong
        // promise, so a note's corner opens the editor.
        view.onDoubleClick = {
            // Said rather than silent: a double click that pastes nothing is
            // the question this log has to answer (the 2026-10-17 report of a
            // note's double click doing nothing on the card).
            diagLog("Card double click: \(isNote ? "note" : "card") \(id)")
            line.open(id)
        }
        view.onSingleClick = { line.copy(id) }
        view.onLongPress = {
            if isNote { NoteController.shared.edit(item) } else { line.markup(id) }
        }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        // The corner mark, which is the second door into the same place for a
        // note: a magnifier over text you cannot edit is the wrong promise.
        view.onZoom = {
            if isNote {
                NoteController.shared.edit(item)
            } else {
                ZoomController.shared.toggleZoom(id: id, anchor: self.zoomAnchor)
            }
        }
        view.onDiscard = { line.discard(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            // A clipboard text card has one copy item, and it is always the
            // other way from the switch: the gestures already give what the
            // switch promises, so the menu is where you reach for the
            // opposite. Read at menu time, so flipping the switch flips the
            // item without this view knowing. A note has no dressing to
            // argue about and a file has none either; both keep Copy.
            if item.payload.isNote {
                menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
                // The editor's door in the menu. The double click now pastes
                // like every other card, so the corner mark alone would be
                // one fragile place to reach a note's own purpose from.
                menu.addItem(ClosureMenuItem(L("Edit")) { NoteController.shared.edit(item) })
            } else if isText {
                if FormatCopy.isEnabled {
                    menu.addItem(ClosureMenuItem(L("Copy plain text")) { line.copy(id, formatted: false) })
                } else {
                    menu.addItem(ClosureMenuItem(L("Copy formatted")) { line.copy(id, formatted: true) })
                }
            } else {
                menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            }
            // The pin, asked for by right click and answered for the card as
            // it stands: a pin on a pinned card would be a lie, so the state
            // is read here rather than carried by the view, which was built
            // for the card as it hung. A note is not a copy — the line keeps
            // it as long as it is written on, and there is nothing to watch.
            if !item.payload.isNote {
                menu.addItem(ClosureMenuItem(line.isPinned(id) ? L("Unpin") : L("Pin")) {
                    line.setPinned(id, !line.isPinned(id))
                })
            }
            // Text has no file to open, annotate or reveal, so those items
            // would be dead — with one exception: a link is a text card whose
            // words name a place, and the browser is where it goes. Markup
            // asks before it shows: the system editor opens pictures and
            // PDFs, and a menu item that ended in Preview for a folder was
            // one promise the item could not keep.
            if !isText {
                menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
                if let url = item.url, Markup.canEdit(url) {
                    menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
                }
                menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            } else if PayloadCard.isLink(item.payload),
                      let link = URL(string: item.payload.captionText ?? ""), link.scheme != nil {
                menu.addItem(ClosureMenuItem(L("Open in Browser")) { NSWorkspace.shared.open(link) })
            }
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            } else if isText {
                // The image card's way of keeping a thing, borrowed for the
                // snippet: it lands on the Desktop as a .txt, named by its
                // first line. The card stays — nothing was moved.
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveTextToDesktop(id) })
            }
            menu.addItem(.separator())
            // No "take down" here any more: the cross in the corner is the way
            // a card leaves the line, and a menu item for the same gesture was
            // one more word doing one job the pointer already does. A pinned
            // card keeps neither item: the pin is a promise to keep it, and
            // the menu is not a side door around the promise.
            if !line.isPinned(id) {
                if inInbox {
                    menu.addItem(ClosureMenuItem(L("Discard")) { line.discard(id) })
                } else if !isText {
                    menu.addItem(ClosureMenuItem(L("Move to Trash")) { line.trash(id) })
                }
            }
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false

    var payload: Payload = .image(URL(fileURLWithPath: "/dev/null"))
    var url: URL?
    var dragImage: NSImage?
    var onDoubleClick: () -> Void = {}
    /// A single click on a clipboard card copies it. A note leaves this
    /// unwired — its press belongs to the squares (2026-10-17, user: a copy
    /// on a single press of a ticked paper is a mis-tick waiting to happen).
    var onSingleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    /// Space over a card: show it at size. A closure rather than a direct
    /// call so the view does not need to know what it is looking at.
    var onZoom: () -> Void = {}
    var menuProvider: () -> NSMenu = { NSMenu() }

    /// The line's panel cannot become key, so this view never receives a key
    /// event by being made first responder — the panel's window is not key
    /// and cannot be. Key events are caught by a monitor on the app instead,
    /// and routed here by the card under the pointer; this flag says that
    /// card wants them.
    var wantsSpaceKey = false
    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    /// The magnifier in the top right corner, handled here for the same
    /// reason the cross is: this view sits on top of the SwiftUI card, so a
    /// button drawn underneath it is a drawing.
    ///
    /// Same size as the cross — twenty points of mark inside twenty-six of
    /// target — and the same shape of answer: the corner of the card is the
    /// only part of it where a press cannot mean "take this", which is why
    /// the mark is a corner at all.
    static let zoomHitSize: CGFloat = 26

    private func isInZoom(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: bounds.width - Self.zoomHitSize,
                            y: isFlipped ? 0 : bounds.height - Self.zoomHitSize,
                            width: Self.zoomHitSize, height: Self.zoomHitSize)
        return corner.contains(p)
    }

    /// The lines of a note and where their squares are, or nothing at all when
    /// this card is not a note. A press inside a square ticks that line; a
    /// press anywhere else on the card does what a press on a card does.
    var noteRows: [NoteCardLayout.Row] = []
    var onTick: (Int) -> Void = { _ in }

    /// Where the ringing card says "知道了", and what that press does. The
    /// caption's right end of a note whose reminder has rung: the one place
    /// on the card that answers "I have seen it" without opening anything.
    /// Nil when the card is not ringing.
    var ackRect: CGRect? = nil
    var onAcknowledge: () -> Void = {}

    /// How far the note's paper can scroll — the distance between the paper
    /// at full length and the window it is seen through. Zero means there is
    /// nothing below the fold and the wheel is left alone.
    var noteScrollMax: CGFloat = 0
    /// How far down the paper currently is, in points.
    var noteScrollOffset: CGFloat = 0
    /// Reports each new wheel position so the card drawing the rows can slide
    /// its own paper by the same amount.
    var onNoteScroll: (CGFloat) -> Void = { _ in }

    /// The wheel over a note scrolls the note.
    ///
    /// This view sits on top of the SwiftUI card, and the same is true of a
    /// wheel as of a press: an `NSScrollView` underneath would never hear the
    /// wheel at all. So the scrolling is done here, in paper points — the
    /// position is handed up and the rows are drawn displaced by it.
    ///
    /// Anything that is not a scrollable note passes the event through, so
    /// the rest of the app keeps whatever it would have done with it.
    override func scrollWheel(with event: NSEvent) {
        guard noteScrollMax > 0 else { super.scrollWheel(with: event); return }
        // `scrollingDeltaY` already carries the user's natural-scrolling
        // direction: fingers up roll the paper up, which is a negative delta
        // and a larger offset — the same sign a page turning under a finger
        // has everywhere else on macOS.
        let next = min(max(noteScrollOffset - event.scrollingDeltaY, 0), noteScrollMax)
        guard next != noteScrollOffset else { return }
        noteScrollOffset = next
        onNoteScroll(next)
    }

    override func mouseDown(with event: NSEvent) {
        if isInZoom(event) {
            downPoint = nil
            onZoom()
            return
        }
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        // Before the tick: a ringing card's 知道了 is a press on paper that
        // is not a square, and letting it fall through to the copy would
        // make the one press the reminder is asking for put the note on the
        // pasteboard instead.
        if isAck(event) {
            downPoint = nil
            onAcknowledge()
            return
        }
        // Before the double click and before the press that copies. A tick is
        // the one press on a card that means something other than "use this",
        // and it is the press that gets made most often, so it is asked about
        // first and it does not wait for the mouse to come up.
        if let row = rowIndex(at: event) {
            downPoint = nil
            onTick(row)
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// Which line's square is under this press, if any.
    ///
    /// The rows are laid out from the top left of the paper with y running
    /// down; this view is not flipped, and it sits around the paper by the
    /// frame's inset. So the height comes off the point, the inset goes on,
    /// and what is left is the same space the rows were laid out in — plus
    /// however far the paper has been scrolled, because a square's place on
    /// the paper does not move when the paper does.
    ///
    /// Given two points of slack all round on top of a target that is already
    /// the marker column by the height of the row. The slack used to be four,
    /// which on a nine point square in a sixteen point row meant every row's
    /// target ran into the next one's — and the loop answers with the first
    /// row it finds, so the bottom edge of one square ticked the row above it.
    ///
    /// Two keeps every target inside its own row: no two overlap, and every
    /// press lands on the line it was aimed at.
    private func rowIndex(at event: NSEvent) -> Int? {
        guard !noteRows.isEmpty else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let inPaper = CGPoint(x: p.x - Frame.inset,
                              y: (bounds.height - p.y) - Frame.inset + noteScrollOffset)
        for row in noteRows {
            guard let box = row.box else { continue }
            if box.insetBy(dx: -2, dy: -2).contains(inPaper) { return row.index }
        }
        return nil
    }

    /// Whether this press landed on the ringing card's 知道了.
    ///
    /// The caption row sits at the card's fixed bottom, below the scroll —
    /// a scrolled note moves its rows, not its footer, so the offset stays
    /// out of the arithmetic here.
    private func isAck(_ event: NSEvent) -> Bool {
        guard let rect = ackRect else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let inPaper = CGPoint(x: p.x - Frame.inset,
                              y: (bounds.height - p.y) - Frame.inset)
        return rect.insetBy(dx: -4, dy: -2).contains(inPaper)
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()

        // One dragging item per writer, so several files arrive as several
        // files. A single item carrying several paths arrives as one thing
        // with paths in it, and a target has no way to make that into a
        // copy of three documents — which is why dragging a card of several
        // did nothing while dragging one worked.
        let items: [NSDraggingItem]
        let writers = fileWriters
        if !writers.isEmpty {
            items = writers.map { NSDraggingItem(pasteboardWriter: $0) }
        } else if let writer = pasteboardWriter {
            items = [NSDraggingItem(pasteboardWriter: writer)]
        } else {
            return
        }
        // A text card has no thumbnail to drag with, so it goes as a small
        // card of its own rather than as nothing at all. Several files share
        // one picture of the stack, since that is what the card shows.
        let contents = dragImage ?? textDragImage
        for (offset, item) in items.enumerated() {
            var frame = imageFrame()
            // Fanned, so a pile of several is visible as several on the way
            // out; stacked exactly, they would look like one.
            if items.count > 1 {
                frame.origin.x -= CGFloat(offset) * 3
                frame.origin.y -= CGFloat(offset) * 3
            }
            item.setDraggingFrame(frame, contents: contents)
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    /// What this card puts on the dragboard: a file for a picture, the string
    /// itself for text, so dropping a snippet into an editor pastes it.
    /// What this card puts on the dragboard.
    ///
    /// A picture is a file URL, and every app that takes a file takes that.
    ///
    /// Text goes out as `public.utf8-plain-text` and nothing else, which is
    /// the opposite of what two earlier rounds concluded. Offering more types
    /// was tried and made no difference: a chat window on Chromium refused
    /// the drag whether the item carried one type or eleven. Flyring's
    /// clipboard, which does reach a Chromium chat window, carries one — the
    /// plain text — and the same byte-writing call rather than the
    /// string-setting one.
    ///
    /// The wider set is not merely useless but actively wrong. `public.uri-list`
    /// is a list of URIs, one per line; handing it a paragraph makes Chromium
    /// fail to parse a drop it had otherwise accepted, and the refusal looks
    /// identical to the drag not being supported. `public.rtf` and
    /// `public.html` are for a target that would lay the text out, and they
    /// make the item a rich document where a text field wants characters.
    ///
    /// So: the bytes, as plain text, and let the target ask for anything
    /// else by copying the card instead.
    /// What goes on the dragboard.
    ///
    /// Files go out as `NSURL`s rather than as one item holding a
    /// newline-separated list of paths. The list is what the pasteboard
    /// carries and what a paste reads, but a drag is not a paste: the target
    /// asks for objects and takes the URLs among them, and a single item
    /// carrying three lines arrives as one object with three paths in it,
    /// which is a thing no target knows what to do with. Several files were
    /// dropped and nothing happened; the Finder's own drag is several URLs
    /// and this is now the same.
    private var fileWriters: [NSPasteboardWriting] {
        payload.files.map { $0 as NSURL }
    }

    private var pasteboardWriter: NSPasteboardWriting? {
        if let first = fileWriters.first { return first }
        // A note drags out as its plain text, the same bytes a paste of it
        // carries — ticks spelled out. It used to fall through the `case
        // .text` below and answer nil, which the drag read as nothing to
        // carry: a note card dragged to another app simply did nothing.
        let string: String
        switch payload {
        case .text(let t, _): string = t
        case .note(let note): string = note.plainText
        default: return nil
        }
        let item = NSPasteboardItem()
        // Written as data rather than with `setString`, which is the same
        // bytes and the same type but goes through a different call.
        guard let data = string.data(using: .utf8) else { return nil }
        item.setData(data, forType: .string)
        return item
    }

    /// Text is dragged as a little note, so the drop target sees something
    /// with a size rather than an invisible item.
    private var textDragImage: NSImage {
        let size = NSSize(width: 120, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
        if let string = payload.pasteboardString {
            let text = String(string.prefix(64)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]
            let bounds = NSRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16)
            text.draw(in: bounds, withAttributes: attrs)
        }
        image.unlockFocus()
        return image
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            endPress()
            downPoint = nil
            didLongPress = false
        }
        // A single press on a clipboard card copies it — the gesture the card
        // is most for, and the same path the menu's Copy takes. The first
        // click of a double click copies as well, which is the cascade every
        // double click lives with: the paste that follows puts the very same
        // thing back on the pasteboard.
        //
        // A note keeps the press for its squares: a click there is a tick or
        // it is nothing. The unification round of 2026-10-17 tried copying on
        // a single press and the user called it back the same evening — on a
        // paper whose rows carry tick boxes, a press that copies is a press
        // one tick away from a mistake. So a note's click answers nothing
        // unless it landed on a square; everything else a note does has its
        // own door (double click pastes, long press edits, the corner mark
        // edits, drag carries the text out).
        guard let start = downPoint, !startedDrag, !didLongPress,
              event.clickCount == 1, !payload.isNote else { return }
        onSingleClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    /// A text card can only be copied and a picture can also be moved or thrown
    /// away, so what the drag offers is decided by what is on the line.
    private var isText: Bool { payload.isImage == false }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        //
        // A text card is never moved or deleted — there is nothing to move and
        // nothing to throw away — so it offers copy alone. Offering more is not
        // harmless: a target that only wants copy shows no cursor when the
        // mask also allows a move, and the drag reads as though it were
        // refused.
        if isText { return context == .outsideApplication ? .copy : [] }
        return context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
