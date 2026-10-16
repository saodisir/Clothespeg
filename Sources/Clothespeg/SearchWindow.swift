import AppKit
import SwiftUI

/// The window the search is typed into.
///
/// It exists because no other window in this app can take a key. The line is a
/// strip over the top of the screen and cannot become key, or it would steal
/// what the user was typing, and no amount of care afterwards gives it back
/// convincingly. The zoom is the same: a reader that took the key window would
/// need a second click to get back to work, which is worse than the small card
/// was.
///
/// So this is the first window here that can. The arrangement is what makes
/// that safe rather than rude:
///
/// - `.nonactivatingPanel`, so taking the key does not activate the app, and
///   the app the user is working in never changes underneath them.
/// - `becomesKeyOnlyIfNeeded`, so it can be key without becoming *main*: the
///   app they are working in keeps its own key window and its own menus.
/// - `hidesOnDeactivate = false`, so it survives a click into another app
///   rather than vanishing — and losing the key is what closes it, which
///   happens either way.
///
/// It is the size of the pill's search half and sits over it, so what looks
/// like one control is one window with a seam down it.
final class SearchWindow: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the line, below a menu. The pill is `.floating`; a search box
        // that slid under an open menu would be a menu with a field in it.
        level = .statusBar
        // Every Space, full screen ones included, like the line it belongs to.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        // Not a floating panel. A floating panel has to become main to take
        // the key, and this one refuses to — so the two together meant a
        // window that could be key in principle and never was in practice,
        // which is a field with a caret in it that cannot be typed into.
        //
        // What stops it being rude is the other two settings rather than this
        // one: `.nonactivatingPanel` means taking the key does not activate the
        // app, so the app the user is working in is not disturbed, and this
        // window never becomes main, so it does not take their menus either.
        contentView = content
    }

    // The one window in this app that can take a key, because it is the only
    // one that has to.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func place(over rect: CGRect) {
        let frame = rect.standardized.integral
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
    }

    /// The caret goes in as soon as the window takes the key.
    ///
    /// Two ways this window becomes key and neither is enough on its own: the
    /// code asks for it, and the user may click the field. Asking for first
    /// responder too early is undone by the app being activated underneath —
    /// the key moves on its way there and arrives back somewhere else — so
    /// this is the later word on the subject, and it is the one that is right
    /// whenever it is the last.
    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isKeyWindow else { return }
            self.focusField()
        }
    }

    /// Hands the caret to the editable field inside the content view.
    ///
    /// The selection is dropped afterwards, because a field that is given the
    /// caret with something already in it arrives with all of it selected —
    /// which is right for a field a person clicked into and wrong for one the
    /// app opened, where the word belongs where it was left rather than as
    /// something the next keystroke would replace. A blue block over the last
    /// search reads as that search being found again.
    func focusField() {
        guard let content = contentView,
              let field = Self.textField(in: content) else { return }
        makeFirstResponder(field)
        clearSelection(in: field)
        // A SwiftUI field builds its editor when it is first made first
        // responder, which is not necessarily by the time this returns. So it
        // is asked again on the next turn, where the editor is the one the
        // caret is actually in.
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field else { return }
            self.clearSelection(in: field)
        }
    }

    /// Takes the selection out of a field and puts the caret at the end.
    ///
    /// A field handed the caret with something already in it arrives with all
    /// of it selected. That is right for a field a person clicked into and
    /// wrong for one the app opened, where the word belongs where it was left
    /// rather than as something the next keystroke would replace — and a blue
    /// block over the last search reads as that search having been found
    /// again.
    private func clearSelection(in field: NSTextField) {
        guard let editor = Self.textView(in: field) else { return }
        let end = (editor.string as NSString).length
        let caret = NSRange(location: end, length: 0)
        guard editor.selectedRange() != caret else { return }
        editor.setSelectedRange(caret)
    }

    /// The view inside a text field that actually holds and selects the text.
    ///
    /// `selectText` is on the field but acts on this: a SwiftUI `TextField`
    /// is an `NSTextField` with a private editor inside it, and the field's
    /// own `stringValue` is only a copy of what the editor is showing.
    private static func textView(in field: NSTextField) -> NSTextView? {
        field.currentEditor() as? NSTextView
    }

    /// The editable text field inside a view, however deep it is.
    ///
    /// A SwiftUI `TextField` is an `NSTextField` with a private editor view
    /// inside it, both inside a hosting view that is not either. Asking the
    /// hosting view for the caret leaves the caret in a container with
    /// nothing in it to type into, which is the one thing that cannot be
    /// fixed by waiting.
    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = textField(in: subview) { return found }
        }
        return nil
    }
}

/// Where the search field is, told by the field rather than worked out from
/// the pill's width — the same reason `pagerRect` is measured rather than
/// guessed at. The panel decides whether a press reaches the pill by asking
/// this, and an arithmetic answer was wrong every time the pill was a
/// different width.
struct SearchRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// What is typed into the field.
///
/// Held apart from both the line and the window, so the two copies of the
/// field cannot disagree: this one is written by whichever copy has the caret
/// and read by both, and by the line for what it shows.
@MainActor
final class SearchModel: ObservableObject {
    /// Whether the field is open. False with a word still in it means the
    /// search is in force and the field is not, which is what a click into
    /// another app leaves behind — and a state worth being able to be in,
    /// because the cards are still filtered and nothing on screen says so
    /// except a lit icon.
    ///
    /// The one thing that decides how the search looks. The window, the pill's
    /// own shape and whether the line knows a search is open are all read off
    /// this rather than set beside it: three places setting a flag that is
    /// supposed to mean one thing is how a window ends up on screen with the
    /// field folded away underneath it, printing the word over whatever took
    /// its place.
    @Published var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            // Optional because nothing is listening yet while this object is
            // being created, and a change in that moment is not one anybody
            // asked for.
            onOpenChanged?(isOpen)
        }
    }

    /// Told what to do when the field opens or closes. Set by the controller,
    /// which is the only thing that knows about the window.
    var onOpenChanged: ((Bool) -> Void)?

    /// The line, so what is typed here is what the line filters by.
    ///
    /// Held rather than wired through bindings because the two copies of the
    /// field — one on the line, one in the window — both write here, and only
    /// one of them has the line to hand.
    var line: Line?

    /// What is typed, mirrored onto the line.
    ///
    /// Written through here rather than by a binding on the view so the line
    /// is the one place that knows a search is in force. A binding written by
    /// two views at once would be a query nobody is watching, and the cards
    /// would not move.
    @Published var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            line?.query = text
        }
    }

    /// The window lost the key. The word stays: the cards on the line are
    /// still filtered by it, and clearing it would put back everything the
    /// user just asked to have hidden.
    func resign() { isOpen = false }

    /// The cross, or Escape: the end of the search rather than a pause in
    /// typing it, so the word goes as well as the focus.
    func close() {
        isOpen = false
        text = ""
    }
}

/// Owns the window, so nothing else has to think about where it is.
///
/// The field is drawn on the line, but the thing that takes a key has to be a
/// window, and a window drawn nowhere would be a rectangle of nothing sitting
/// on top of the pill. So the two are made to agree: the copy on the line
/// reports its own rectangle, the window is put over it, and the window's own
/// field is the one the caret goes into.
@MainActor
final class SearchController {
    static let shared = SearchController()

    private(set) var window: SearchWindow?
    private var host: NSView?

    let model = SearchModel()

    /// Whether the line is down. A search box floating over an app with no
    /// line under it is a search for nothing.
    var isLineRevealed = false

    /// Where the field on the line was last seen, in the panel's own space.
    ///
    /// Kept rather than acted on alone, because the two do not arrive in the
    /// order they are needed: the field reports itself on every layout, which
    /// is from the moment the line comes down, and the window does not exist
    /// until the magnifier is pressed. The report that came before the window
    /// existed is the one that says where to put it.
    private var lastFieldRect: CGRect = .zero
    private var lastPanelFrame: CGRect = .zero

    /// When the field was last opened. Read by the resign handler to tell a
    /// resign belonging to this opening from one belonging to the last.
    private var openedAt: Int = 0

    private init() {
        // Everything that has to happen when the field opens or closes is
        // decided here and nowhere else. The window going away is not a thing
        // each caller remembers to do: it was left on screen once, printing
        // the word over a filter that had taken its place, because the caller
        // that closed the field had no reason to know there was a window.
        model.onOpenChanged = { [weak self] open in
            guard let self else { return }
            if open {
                // The line has to know too, or the pill draws its closed shape
                // — an icon and a hole — while the field is open over it, and
                // the two are the same control in two states at once.
                self.model.line?.isSearching = true
                self.openedAt &+= 1
                self.orderIn()
            } else {
                // Closed. The window goes, or it goes on printing the word
                // over whatever is now in its place. And the line stops
                // believing a search is open, or the next time it comes down
                // it comes down already expanded, with no field to type in.
                self.window?.orderOut(nil)
                self.model.line?.isSearching = false
            }
        }
    }

    // MARK: Opening and closing

    /// The magnifier was pressed: the field opens, and the window that can
    /// take a key comes with it.
    ///
    /// Put in place before it comes forward. A window ordered in at the wrong
    /// size is on screen before it can be moved, and a field that appears as
    /// a bar across the screen and then shrinks is worse than one that
    /// arrives already the right size.
    func activate() {
        guard isLineRevealed else { return }
        // The field has to be on screen before the window goes over it, or
        // there is nothing for the window to line up with yet: this call is
        // what makes the pill draw the hole the window fills.
        placeWindowOverField()
        // Opening is what brings the window; nothing below this line decides
        // it separately, because a window ordered in by one caller and out by
        // another is a window that is sometimes neither.
        model.isOpen = true
    }

    /// Brings the window in and gives it the key.
    private func orderIn() {
        guard let panel = window ?? makeWindowIfNeeded() else { return }
        placeWindowOverField()
        panel.makeKeyAndOrderFront(nil)

        // A tick later, not now. Becoming key makes the app active, and the
        // activation moves the key around on its way — a field that took the
        // caret before that finished had it taken back, which reads as a
        // search that opened and could not be typed into.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.window, panel.isVisible else { return }
            self.focusTheField(in: panel)
        }
    }

    /// Puts the caret in the field.
    ///
    /// The window does this for itself when it takes the key, and this is the
    /// other path: the window can be made key and then lose the key again
    /// during the app activation that follows, and the field has to be asked
    /// for once more after that settles.
    private func focusTheField(in panel: SearchWindow) {
        panel.focusField()
        let responder = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        log.notice("Search focused: isKey=\(panel.isKeyWindow) responder=\(responder)")
    }

    /// Moves the window over the field, if there is a field to move it over.
    private func placeWindowOverField() {
        guard let window, isLineRevealed,
              lastFieldRect != .zero, lastPanelFrame != .zero else { return }
        // The line's space has its origin at the top left the way SwiftUI's
        // does; AppKit's is at the bottom left, so the height comes back off.
        let onScreen = CGRect(x: lastPanelFrame.minX + lastFieldRect.minX,
                              y: lastPanelFrame.maxY - lastFieldRect.maxY,
                              width: lastFieldRect.width,
                              height: lastFieldRect.height)
        window.place(over: onScreen)
    }

    /// Escape, or the cross: the end of the search rather than a pause in
    /// typing it, so the word goes as well as the focus.
    ///
    /// Closing the field is all this says. The window going away and the line
    /// forgetting a search is open are both consequences of that, not things
    /// to remember here as well.
    func close() {
        model.close()
    }

    /// The line tucked away. The word stays — the line will come back, and the
    /// cards on it are still filtered — but the field closes, because a field
    /// over an app with no line under it is a search for nothing.
    ///
    /// The word is not touched. The cards on the line are still filtered by
    /// it, and a search that cleared itself when the line tucked away would
    /// bring back every card the user had just asked to have hidden.
    func lineDidHide() {
        isLineRevealed = false
        model.resign()
    }

    /// The line came back.
    ///
    /// A search that is still in force comes back open, with its word in it.
    /// It was closed only because there was no line to type into, and a field
    /// that has to be reopened from an icon every time leaves the state of the
    /// search somewhere else: the lit icon says a search is on and nothing
    /// about what it is looking for.
    ///
    /// A tick later, because the line being down and the pill having laid
    /// itself out are two moments: opening on the first would put the window
    /// where the field was last time, and show it moving. Every layout
    /// re-places the window anyway, so the only thing the wait buys is that
    /// the window never appears in the wrong place on its way to the right
    /// one.
    func lineDidShow() {
        isLineRevealed = true
        guard !model.text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLineRevealed else { return }
            self.model.isOpen = true
        }
    }

    /// Whether the field is open, which is also the only time this app has a
    /// window that can take a key.
    var isOpen: Bool { model.isOpen }

    /// Whether a point in the line panel's own space is over the input field.
    ///
    /// The panel asks before it decides whether to keep the click or let it
    /// through to the window above, and the answer has to be measured rather
    /// than worked out: the pill is a different width depending on the
    /// filter, whether its segments are open and what is in the field, so
    /// arithmetic about where the field is would be wrong often enough to
    /// swallow the click that was meant for it.
    func isOverField(_ point: CGPoint) -> Bool {
        guard model.isOpen, lastFieldRect != .zero else { return false }
        return lastFieldRect.insetBy(dx: -2, dy: -2).contains(point)
    }

    // MARK: Geometry

    /// Where the field ended up, in the window's own space.
    ///
    /// The window is moved to match rather than the field being told where the
    /// window is, because the field is what the user clicks and the window is
    /// what has to be under the click.
    ///
    /// Remembered rather than only acted on: this is called on every layout,
    /// which is from before the search is opened, and the opening is where the
    /// window needs to know. A report that arrived while there was no window
    /// to move is still the answer to "where is the field".
    ///
    /// Screen coordinates, which is what the field reports in and what a
    /// window's frame is. It used to be the panel's space and converted here,
    /// and the conversion was wrong by the height of the panel on every launch
    /// where the line had been tucked away and came back.
    func fieldDidMove(to rect: CGRect, panel: CGRect) {
        guard rect != .zero else { return }
        lastFieldRect = rect
        lastPanelFrame = panel
        placeWindowOverField()
    }

    // MARK: The window itself

    private func makeWindowIfNeeded() -> SearchWindow? {
        if let window { return window }
        // Only the field goes in the window. The glass and the cross belong
        // to the pill underneath, which has already drawn them; drawing them
        // again would put two crosses on top of each other the moment the
        // window appeared over it.
        let host = NSHostingView(rootView: SearchInput(search: model))
        // A field with no size is a field with no caret: `sizingOptions = []`
        // turns off every negotiation between the view and its window, so a
        // window made around it keeps whatever rectangle it was given — which
        // was none. The size here is the field's own, and the real rectangle
        // arrives with the first report from the line.
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0,
                            width: SearchField.windowWidth + 12, height: SearchField.height)
        let panel = SearchWindow(content: host)
        self.host = host
        self.window = panel

        // Losing the key is how this window closes itself — but not straight
        // away, because making a window key goes through a moment where it
        // briefly is not, and a search that closed itself in that moment
        // would be a search that could never be opened.
        //
        // The word is kept either way: only the focus goes, because the cards
        // on the line are still filtered by it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isOpen else { return }
                // Which opening this belongs to. The wait is long enough for
                // the user to press the magnifier again, and a resign left
                // over from the last time would close the search they just
                // opened — the same bug, one keystroke later.
                let openedAt = self.openedAt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    // The window may have taken the key back in the meantime,
                    // which is what happens when the system activates the app
                    // underneath it while opening.
                    guard panel.isKeyWindow == false else { return }
                    guard self.openedAt == openedAt else { return }
                    self.model.resign()
                }
            }
        }

        // Escape ends the search. A local monitor, because a monitor sees the key
        // before the field does: the field's own `cancelOperation` would ask
        // first, and on a field that has something in it that is where Escape
        // is wanted — to stop editing rather than to leave. The second press,
        // on an empty field, is the one the field would answer, and by then
        // there is nothing to leave.
        //
        // So the monitor takes the first press and the field never sees it,
        // which is what makes one Escape always mean the same thing: out of
        // the search, not out of the word.
        //
        // A local monitor rather than another global one because a global one
        // cannot take a key back: Escape would also reach whatever app the
        // user was working in, which in most of them is not an Escape at all.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            guard event.keyCode == 53, let self else { return event }
            let shouldClose: Bool = MainActor.assumeIsolated {
                // Only while the field is open. Escape with nothing being
                // searched is the line's own Escape, which closes the zoom,
                // and taking it here would be stealing it.
                guard self.model.isOpen else { return false }
                self.close()
                return true
            }
            return shouldClose ? nil : event
        }
        return panel
    }

    private var escapeMonitor: Any?
}

/// The search, on the pill.
///
/// Only the cross is drawn here. The field itself belongs to the window —
/// the one that can take a key — and drawing a second copy of it underneath
/// meant two renderings of the same word a point or two apart, which reads as
/// a shadow behind the text rather than as two views of one thing.
///
/// So this is the part of the control that stays on the line, and the space
/// it leaves is the space the window fills. The width is reported rather than
/// drawn, because the window has to be put exactly over this hole.
struct SearchField: View {
    @ObservedObject var search: SearchModel

    var body: some View {
        HStack(spacing: 0) {
            Button {
                SearchController.shared.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The hole the window goes into. Not a field and not a
            // placeholder: anything drawn here is drawn again by the window
            // on top of it, and two copies of one word is a smudge.
            //
            // Full height, not a hairline. The rectangle this reports is the
            // rectangle the window is made, so a one-point hole made a
            // one-point window and the field was squeezed into it — which
            // showed as the word appearing clipped to a sliver rather than as
            // a window that was the wrong size.
            //
            // Wider than the field, because the window holds the field and
            // the note about how to leave it. The note is outside the field
            // on purpose: a hint about Escape typed into a field that is
            // being searched for would be a search for the word "escape".
            //
            // The cross is not inside it: the window goes over the hole, and a
            // window over the cross as well would be a window in the way of
            // the one control that closes the search.
            Color.clear
                .frame(width: SearchField.windowWidth, height: SearchField.height)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: SearchRectKey.self,
                                               value: g.frame(in: .named("lineSpace")))
                    }
                )
        }
        .frame(height: SearchField.height)
    }

    /// How wide the field itself is: enough for a word and a bit, which is all
    /// a search box has to be. Wider would make the pill a bar.
    static let width: CGFloat = 120
    /// The whole window: the field, and the note beside it saying how to leave.
    static let windowWidth: CGFloat = 186
    /// The pill's row height, which is what the hole is cut to.
    static let height: CGFloat = 22
}

/// The editable field, drawn once, in the window that can take a key.
struct SearchInput: View {
    @ObservedObject var search: SearchModel

    var body: some View {
        HStack(spacing: 0) {
            // The field and its placeholder. The placeholder rides on the
            // field itself (`prompt`) rather than as a `Text` drawn behind it.
            // Drawn behind, the hint could not see what the field editor
            // holds: an input method's composing text — pinyin, romaji,
            // anything marked — lives in the editor but is not the field's
            // text until it is committed, so the binding stayed empty, the
            // hint stayed under the word being written over it, and only
            // Enter's commit swept it away. The field's own placeholder
            // yields to anything the editor holds, marked text included,
            // which is the whole of the difference. It is also not
            // selectable — the field never offers it as text — so the blue
            // block can never land on what was only ever a hint.
            TextField(
                "",
                text: $search.text,
                prompt: Text(L("Type to search"))
                    .font(.system(size: 11, weight: .medium))
                    // The placeholder is not the text: it is the hint that
                    // there is a place to type, so it is the colour of
                    // something unread rather than something being read.
                    .foregroundStyle(.tertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            // Escape, through the responder chain rather than through
            // an event monitor. `cancelOperation` is what a field
            // answers Escape with, and it arrives whether or not there
            // is anything to clear — which is the whole question here,
            // because the first press has nothing to clear and still
            // has to mean "leave".
            .onExitCommand { SearchController.shared.close() }
            .frame(width: SearchField.width, height: SearchField.height)

            // How to leave, said once and then never again.
            //
            // Beside the field rather than inside it: a hint about Escape
            // typed into a field that is searching for something would be a
            // search for the word "escape". And it goes as soon as anything
            // has been typed, because it is a way in and you are already
            // through it — leaving it up would be a note about how to start
            // over sitting in the middle of a search in progress.
            if search.text.isEmpty {
                Text(L("esc to leave"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .padding(.leading, 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: SearchField.windowWidth, height: SearchField.height)
        .padding(.horizontal, 6)
        // The note goes as you start typing rather than being cut off at the
        // moment it stops applying, which is the difference between something
        // that was said and something that was taken away.
        .animation(.easeOut(duration: 0.12), value: search.text.isEmpty)
    }
}

/// The closed state: one icon that opens the search.
///
/// Its own view rather than a hidden `SearchField`, because what sits on the
/// pill when nothing is being typed is an icon and a piece of glass, not an
/// empty field.
struct SearchButton: View {
    @ObservedObject var line: Line
    @ObservedObject var search: SearchModel

    var body: some View {
        Button {
            SearchController.shared.activate()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                // A lit mark means on. This is on while a word is in force
                // even with the field shut — the cards are still filtered and
                // nothing else on screen says so — and grey otherwise, which
                // is the same distinction the filter draws with its colour.
                //
                // Its own question only. It used to be asked of `narrows`,
                // which is whether *anything* is hiding cards, and a date
                // range lit it: setting a date turned the search mark on with
                // no word in the field behind it, which is a control claiming
                // a state it is not in.
                .foregroundStyle(!search.text.isEmpty ? Color.accentColor : Color.secondary)
                // The pill's icon-button shape: content, four points of air on
                // each side, eighteen points tall. The divider outside carries
                // the rest of the gap, which is how every button on the pill
                // sits the same distance from the line beside it.
                .padding(.horizontal, 4)
                .frame(height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}