import AppKit
import AVFoundation
import Combine
import os
import UniformTypeIdentifiers

let log = Logger(subsystem: "app.clothespeg.Clothespeg", category: "line")

/// One item hanging on the line: a photo, or something copied.
struct Pegged: Identifiable, Equatable {
    /// Given back when the card comes out of the history, and minted when it
    /// is new.
    ///
    /// A card restored with a fresh one would be a stranger to the history it
    /// came from, and the next save — which keeps what it does not recognise —
    /// would append every card again. That is where a count that doubled on
    /// every launch came from: 164, then 328, then 656.
    let id: UUID
    /// What is on the card.
    ///
    /// The one `var` on this type, and the reason is the one card that is
    /// written rather than copied: a note is edited where it hangs — a line
    /// added, a box ticked — and a card is a value, so the edit is a new
    /// payload replacing the old one rather than a reference into the middle
    /// of a card. Everything else here is what it was when it was hung.
    var payload: Payload
    /// Where it was copied from. Pictures carried their capture date before
    /// this; text has nothing but this to say where it came from.
    var origin: Origin = Origin()
    /// Set for `.image`, and for a `.file` whose single file is a picture:
    /// the card renders a downscaled copy, so a large screenshot never costs
    /// more than a small one, and a picture file shows itself rather than a
    /// Finder icon.
    var thumb: NSImage?
    /// The formatting a text copy arrived with, kept whether the switch is on
    /// or not: the choice is read when the card goes out, so this is what
    /// makes a copy with formatting possible on any card still hanging.
    var rich: RichText?
    /// Every item hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// Watched by the user: right-click a card and choose "Pin", and the
    /// retention window stops applying to it. A pin is the user's own answer
    /// to "how long should this be kept", which is otherwise the settings'
    /// question to answer for everybody at once.
    var pinned = false

    /// The file this card is, if it is one. A picture is a file too, so
    /// dragging works for both without caring which it is.
    var url: URL? { payload.fileURL }
    var isText: Bool { payload.captionText != nil }
    /// Whether this card is one or more files rather than a picture. A picture
    /// is a file too, and is not one of these: it shows itself, which is the
    /// whole difference.
    var isFile: Bool { !payload.files.isEmpty && payload.imageURL == nil }

    init(id: UUID = UUID(), payload: Payload, origin: Origin = Origin(), thumb: NSImage? = nil, rich: RichText? = nil, pinned: Bool = false) {
        self.id = id
        self.payload = payload
        self.origin = origin
        self.thumb = thumb
        self.rich = rich
        self.pinned = pinned
    }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying
            && a.payload == b.payload && a.origin == b.origin && a.thumb === b.thumb
            && a.rich == b.rich && a.pinned == b.pinned
    }

    /// Whether this card has anything to say about what is being looked for.
    ///
    /// Everything the card shows, plus what it came from. A search that only
    /// read the words on the card would not find a screenshot named
    /// `q3-report.png` or a snippet copied out of Safari, and those are the
    /// two things people remember about a line — not the pixels, which cannot
    /// be matched against a word at all.
    ///
    /// The text of a snippet is matched in full rather than in the part that
    /// fits on the card: a word cut off by `lineLimit` is still in the
    /// snippet, and a search that cannot find it would be lying about what is
    /// on the line.
    ///
    /// Not cached on the card: a card is a value, so a stored copy is rebuilt
    /// on every copy of it, and the line copies its cards as it lays them out.
    /// Caching here would be slower than not caching. Folding is done by the
    /// caller instead, once per keystroke, and the parts are built once for
    /// the whole line rather than once per card.
    func matches(_ search: String) -> Bool {
        Self.parts(of: self).contains { $0.contains(search) }
    }

    /// What on this card can be found by typing.
    ///
    /// Folding is what makes the search read the way the words look rather
    /// than the way they are stored: case aside, accents aside, so a card
    /// copied from Safari is found by `safari` and one copied from Zürich by
    /// `zurich`.
    static func parts(of item: Pegged) -> [String] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func fold(_ string: String) -> String {
            string.folding(options: options, locale: .current)
        }

        var parts: [String] = []
        if let text = item.payload.captionText {
            parts.append(fold(text))
            // A link is stored as its text, so it is never in `files` and its
            // host would otherwise be unsearchable. The path of a link is
            // `/articles/one`, which says nothing about where it leads, and a
            // card showing a link is named by where it goes — so the host is
            // matched too, and a bare path would only find it by the slash.
            if PayloadCard.isLink(item.payload), let host = URL(string: text)?.host {
                parts.append(fold(host))
            }
        }
        if let app = item.origin.app { parts.append(fold(app)) }
        for url in item.payload.files {
            // The name is what is written on the card, so it is what a search
            // has to find by. The whole path is matched as well, because the
            // folder a file is in is most of what says which of two files
            // named "final" is the one being looked for.
            parts.append(fold(url.path))
        }
        return parts
    }
}

/// The days a card has to have been copied on.
///
/// The end of the range is the last moment of the last day rather than the
/// first moment of it, which is the difference between "the eleventh" and
/// "the twelfth, one second in". A picker hands back the day it means as a
/// moment somewhere inside it, and that moment is not the end of anything.
struct DateRange: Equatable {
    /// The first moment of the first day.
    let from: Date
    /// The last moment of the last day: midnight of the day after, less one
    /// second.
    let until: Date

    /// Built from two days as the picker gives them.
    ///
    /// The end is stretched to the end of its day rather than left where it
    /// fell: someone picking the eleventh and the eleventh means the eleventh,
    /// and a range from 09:00 to 09:00 that day would show nothing at all.
    init(from: Date, until: Date) {
        // Sorted, so a caller that hands the two over the wrong way round
        // gets a range rather than a crash. Nobody does today; the point is
        // that a wrong order here is a wrong selection and not the end of the
        // app, and the difference is four lines.
        let early = min(from, until)
        let late = max(from, until)
        let start = Calendar.current.startOfDay(for: early)
        let end = Calendar.current.date(byAdding: .day, value: 1,
                                        to: Calendar.current.startOfDay(for: late))
        self.from = start
        // One second short of the next midnight, because the end of a range
        // is the last moment of the last day and not the first moment of the
        // one after it: a card copied at 23:59:59.5 would otherwise fall
        // outside its own day.
        self.until = (end ?? late).addingTimeInterval(-1)
    }

    /// Whether a moment falls inside.
    ///
    /// Two comparisons rather than a range. `(from...until)` is the same
    /// expression and a fatal error the one time the two are the wrong way
    /// round — which cannot happen here, and is exactly the kind of thing that
    /// cannot happen until it does. A comparison has no such shape.
    func contains(_ moment: Date) -> Bool {
        moment >= from && moment <= until
    }

    /// Whether this is one day rather than several — which is what makes a
    /// click on the day already showing an undo rather than a re-selection.
    var isSingleDay: Bool {
        Calendar.current.isDate(from, inSameDayAs: until)
    }

    /// "今天" or "10月1日–10月11日", for the button that opened this.
    var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(from) && calendar.isDateInToday(until) {
            return L("Today")
        }
        let sameDay = calendar.isDate(from, inSameDayAs: until)
        let start = Self.day(from)
        return sameDay ? start : "\(start)–\(Self.day(until))"
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]
    /// Where the page counter is on screen, told by the pill itself rather
    /// than worked out from its width: it grows when the filter opens and it
    /// is not always in the middle, so any arithmetic about it is a guess that
    /// a press has to be lucky against.
    var pagerRect: CGRect = .zero
    /// Where the plus above the middle of the rope is, told by the mark
    /// itself for the same reason the pill tells: the press that opens a new
    /// note is decided outside SwiftUI, and a mark this small is not
    /// somewhere a guess lands in.
    var plusRect: CGRect = .zero
    /// The panel's frame on screen, which a card needs to turn its own
    /// position into somewhere a window can be placed.
    var panelFrame: CGRect = .zero
    /// Whether the line is propped down and stays until released. Set by the
    /// app delegate; the peg and the menu read it. A propped line does not
    /// retract on its own the way a line brought down by a gesture does.
    @Published var propped = false
    /// Which marks the rope draws, mirrored from `RopeMark`'s stored answer so
    /// that a switch thrown in the settings reaches a line that is already
    /// down. Reading `UserDefaults` at draw time would work right up until the
    /// user opened the settings with the rope showing and turned a mark on:
    /// nothing would publish, so nothing would redraw, and the switch would
    /// appear to do nothing until the line was put away and brought back.
    @Published var showsNoteMark = RopeMark.isShown(.note)
    @Published var showsPropMark = RopeMark.isShown(.prop)
    /// The action the prop peg takes. Wired by the app delegate; the view
    /// only draws the pin and calls this when it is pressed. The toggle lives
    /// in the pager now, so the prop test in AppKit reads the pager's own
    /// rectangle rather than a mark of its own.
    var onPropToggle: (() -> Void)?

    /// Everything that has been hung, newest first. The line is a window onto
    /// this, not the whole of it.
    let attic = Attic()

    /// Every note that has been written, newest first.
    ///
    /// A second list rather than a corner of `items`, because the two are kept
    /// by different rules and reached through different doors: a copy is what
    /// somebody else produced and this app caught, a note is what was written
    /// here. One list would mean every rule about the line having to ask which
    /// kind it was looking at, which is how one rule ends up applied to the
    /// wrong half of it.
    ///
    /// The setter is open where `items`' is not, and the reason is where the
    /// code is kept rather than a difference in the rule: every change to this
    /// list is made by the notes half, and that half is an extension in a file
    /// of its own. Closing it would mean either putting the writing of notes
    /// back among the clipboard's rules or handing out copies to be changed
    /// and given back — and both of those are worse than one door that is open
    /// to the thing standing on the other side of it.
    @Published var notes: [Pegged] = []

    /// Which of the two is on the line. They share the panel, the rope, the
    /// glass and every gesture, and share nothing else.
    enum Deck: String {
        case clipboard
        case notes
    }

    /// Set by whichever door was used.
    ///
    /// Remembered for the same reason the filter is: which one you are looking
    /// at is a way of looking rather than a gesture, and coming back to the
    /// other one on every launch would be the app disagreeing with where it
    /// left you.
    @Published var deck: Deck = Line.restoreDeck() {
        didSet {
            guard deck != oldValue else { return }
            // Whatever was at the front of the old deck may not be in the new
            // one, so start at the newest that is rather than showing a gap.
            panToNewest()
            UserDefaults.standard.set(deck.rawValue, forKey: "lineDeck")
            // The controls that narrow the line belong to the half that has
            // something to narrow, and they are drawn on the pill — so they go
            // with the deck rather than staying open over a list they cannot
            // say anything about.
            //
            // The search is why this is not only tidying. Its field is one
            // view on the pill and its caret is a window placed over that
            // view, so a search left open across the change would be a window
            // floating over a field that is no longer drawn — a caret in the
            // middle of the screen with nothing under it.
            NotificationCenter.default.post(name: .filterCollapsed, object: nil)
            if isSearching { SearchController.shared.close() }
        }
    }

    /// What is on the line right now, whichever deck is up.
    ///
    /// Everything that draws, narrows or counts the line reads this rather
    /// than `items`, so the two decks cannot drift apart: there is one place
    /// that decides what the line is showing, and it is here.
    var onLine: [Pegged] { deck == .clipboard ? items : notes }

    /// Whether a chosen deck is holding anything, regardless of which deck
    /// the line is up showing. The settings' cleanup buttons ask this rather
    /// than `onLine`, which answers for the deck on display — a gray button
    /// above a full clipboard was the lie that taught the difference.
    func hasCards(_ target: Deck) -> Bool {
        target == .clipboard ? !items.isEmpty : !notes.isEmpty
    }

    private static func restoreDeck() -> Deck {
        guard let raw = UserDefaults.standard.string(forKey: "lineDeck"),
              let stored = Deck(rawValue: raw) else { return .clipboard }
        return stored
    }

    /// How far along the line the view is panned, in cards. Zero shows the
    /// newest, which is where a new copy puts it.
    @Published private(set) var panOffset: Int = 0


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { onLine.filter { !$0.falling }.count }

    /// What the line is showing.
    ///
    /// A link and a colour are both text, and they are apart here because a
    /// card already looks like one or the other — a link is blue, a colour is
    /// its own colour — so a line of text and a line of links are two things
    /// you might want to see separately. Code is not: it looks like text, so
    /// it is text.
    enum Filter: String, CaseIterable {
        case all, text, link, colour, image, file

        /// The name on the menu and the segment. Kept short so the segments
        /// fit in one row without the control growing a second line.
        var label: String {
            switch self {
            case .all: return L("All")
            case .text: return L("Text")
            case .link: return L("Links")
            case .colour: return L("Colours")
            case .image: return L("Pictures")
            case .file: return L("Files")
            }
        }

        func accepts(_ payload: Payload) -> Bool {
            switch self {
            case .all: return true
            case .text:
                guard case .text = payload else { return false }
                return payload.colorValue == nil && !PayloadCard.isLink(payload)
            case .link:
                return PayloadCard.isLink(payload)
            case .colour:
                return payload.colorValue != nil
            case .image:
                return payload.imageURL != nil
            case .file:
                return !payload.files.isEmpty && payload.imageURL == nil
            }
        }
    }

    /// The filter in force. Remembered rather than reset, so a line that is
    /// looked at through "pictures" stays on pictures until it is asked for
    /// something else — a filter is a way of looking, not a momentary gesture.
    @Published var showing: Filter = .all {
        didSet {
            guard showing != oldValue else { return }
            // Whatever was at the front of the old filter may not exist in the
            // new one, so start at the newest that does rather than showing a
            // gap.
            panToNewest()
            saveFilter()
        }
    }

    private func saveFilter() {
        UserDefaults.standard.set(showing.rawValue, forKey: "lineFilter")
    }

    /// Whether the line is looking at watched cards alone.
    ///
    /// Deliberately not a `Filter` case: the six kinds are ways of looking at
    /// what a card *is*, and the pin is what the user *did* to one — a switch
    /// that rides beside the kinds rather than among them, on the pill as a
    /// lone icon with two states and no words. Remembered like the kinds are,
    /// so a line left looking at what is watched comes back that way.
    @Published var showingPinned: Bool = UserDefaults.standard.bool(forKey: "linePinnedOnly") {
        didSet {
            guard showingPinned != oldValue else { return }
            UserDefaults.standard.set(showingPinned, forKey: "linePinnedOnly")
            // Whatever sat at the front may not be watched, so start at the
            // newest thing that is rather than showing a gap.
            panToNewest()
        }
    }

    /// What is being looked for, or nothing. Deliberately not remembered
    /// across a relaunch: a filter is a way of looking and belongs to the
    /// session, and a search is a question being asked right now — yesterday's
    /// search reopened tomorrow would be a question nobody asked.
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            // Whatever was at the front may not contain the new word, so
            // start at the newest thing that does rather than showing a gap.
            panToNewest()
        }
    }

    /// Whether the search field is open, which is not the same as whether a
    /// search is in force. An open field with nothing in it is looking at
    /// everything, and closing it should not be the only way to stop looking.
    @Published var isSearching = false

    /// A query that says anything. Whitespace is not a question, so a field
    /// holding only spaces is an empty search rather than a search for spaces.
    var activeQuery: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed
    }

    /// When to look, or nothing to say about when.
    ///
    /// A range rather than a day, because "yesterday" is not a question worth
    /// asking when a clipboard is a hundred cards long and one of them is
    /// from last Tuesday — the day that gets found is rarely the day asked
    /// about.
    ///
    /// Nil when no range is in force, which is most of the time. Remembered
    /// across a relaunch for the same reason a filter is: it is a way of
    /// looking, not a momentary gesture, and arriving to a line already
    /// looking at last Tuesday is a surprise.
    @Published var dateRange: DateRange? {
        didSet {
            guard dateRange != oldValue else { return }
            panToNewest()
            saveDateRange()
        }
    }

    private func saveDateRange() {
        let defaults = UserDefaults.standard
        guard let range = dateRange else {
            defaults.removeObject(forKey: "lineDateFrom")
            defaults.removeObject(forKey: "lineDateTo")
            return
        }
        // Stored as the interval, not as instants. A range is two days, and
        // the days it names are the same tomorrow; storing the exact instants
        // would move both ends by the time zone on the next launch and ask
        // for a window one day narrower than the one chosen.
        defaults.set(range.from.timeIntervalSince1970, forKey: "lineDateFrom")
        defaults.set(range.until.timeIntervalSince1970, forKey: "lineDateTo")
    }

    private static func restoreDateRange() -> DateRange? {
        let defaults = UserDefaults.standard
        guard let from = defaults.object(forKey: "lineDateFrom") as? Double,
              let until = defaults.object(forKey: "lineDateTo") as? Double else { return nil }
        let range = DateRange(from: Date(timeIntervalSince1970: from),
                              until: Date(timeIntervalSince1970: until))
        // A range that ends before it starts is a range whose ends were
        // swapped by someone dragging one past the other. Reads as nothing
        // rather than as everything.
        guard range.from <= range.until else { return nil }
        return range
    }

    private static func restoreFilter() -> Filter {
        guard let raw = UserDefaults.standard.string(forKey: "lineFilter"),
              let stored = Filter(rawValue: raw) else { return .all }
        return stored
    }

    /// The cards the line is showing, narrowed by the filter, then the search,
    /// then the dates, newest first.
    ///
    /// Filtered here rather than at the point of drawing, so the count on the
    /// pager, the room for the cards and where a pan may go all agree about
    /// what is on the line.
    ///
    /// The three narrow each other rather than choosing between them. Choosing
    /// "pictures" and typing `pdf` asks for the pictures whose name has pdf in
    /// it, and adding a range asks for those of them copied in those days —
    /// which are three questions about the same line rather than three ways
    /// of asking one question. A second way of choosing a kind, sitting next
    /// to the first, would be one control too many.
    ///
    /// None of that applies to a note, and this is the one place that says so.
    /// A note was not copied, so it has no kind to filter by, no app it came
    /// from to search and no day it arrived on: the three ways of narrowing
    /// the line are three questions about a copy. What answers them is left
    /// alone rather than cleared, so switching back to the clipboard finds the
    /// line looking at what it was looking at.
    var matching: [Pegged] {
        let live = onLine.filter { !$0.falling }
        guard deck == .clipboard else { return live }
        var cards = live
        // The pin rides beside the kinds: both may narrow at once, and either
        // alone is enough.
        if showingPinned { cards = cards.filter { $0.pinned } }
        if showing != .all { cards = cards.filter { showing.accepts($0.payload) } }
        if let dates = dateRange {
            cards = cards.filter { dates.contains($0.origin.at) }
        }
        let search = activeQuery
        guard !search.isEmpty else { return cards }
        // Folded once here rather than inside each card: the whole line is
        // walked on every keystroke, and a card holding a long path should not
        // have that path folded again for every other card that does not.
        let folded = search.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: .current)
        return cards.filter { Pegged.parts(of: $0).contains { $0.contains(folded) } }
    }

    /// Whether anything is hiding cards right now: a filter that lets some
    /// through, a search with a word in it, a range of days — or the pin,
    /// which narrows the way the others do even though it wears its own
    /// button.
    ///
    /// Never true for the notes deck, which is the reason the pill there is a
    /// counter and two arrows rather than a row of controls that would have
    /// nothing behind them.
    var narrows: Bool {
        deck == .clipboard && (filterHidesSomething || !activeQuery.isEmpty || dateRange != nil || showingPinned)
    }

    /// Whether the filter is hiding anything at all. When it is not, the
    /// control has nothing to say and does not appear.
    var filterHidesSomething: Bool {
        deck == .clipboard && showing != .all
            && matching.count != onLine.filter { !$0.falling }.count
    }

    /// The cards the line can show: everything after the pan, capped at what
    /// fits on the screen.
    func visibleItems(_ fits: Int) -> [Pegged] {
        let live = matching
        let count = max(fits, 1)
        let last = max(0, live.count - count)
        let start = min(max(panOffset, 0), last)
        return Array(live.dropFirst(start).prefix(count))
    }

    /// Moves the view along the line, stopping at either end rather than
    /// sliding off into empty space.
    ///
    /// The cards run newest first, so a positive delta moves towards the past.
    /// A swipe to the right drags the line with it, which brings what is
    /// further back into view — the same way a drawer of files opens the way
    /// you pull it.
    func pan(by delta: Int, fits: Int) {
        let live = matching.count
        let last = max(0, live - max(fits, 1))
        panOffset = min(max(panOffset + delta, 0), last)
    }

    /// A new copy is the thing you want to see, so it brings the line back.
    func panToNewest() {
        panOffset = 0
    }

    init() {
        showing = Self.restoreFilter()
        dateRange = Self.restoreDateRange()
        restore()
        // The notes come back from a file of their own, with no window applied
        // to them: what was written down to be kept is kept.
        restoreNotes()
        // A picture that comes back from the system Markup editor has been
        // written over its own file, and the card shows the edited version.
        Markup.shared.onSaved = { [weak self] url in self?.reloadThumbnail(for: url) }
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ payload: Payload, origin: Origin = Origin(), quietly: Bool = false, flying: Bool = false, rich: RichText? = nil) -> UUID? {
        // Every card on the line is handed to the zoom as it is hung, so a
        // press on a card's magnifier can be answered without asking where
        // the pointer is — which is the question a global monitor cannot ask
        // and a card cannot answer.
        defer { ZoomController.shared.register(contentsOf: items) }

        // Copying the same thing twice in a row is not a second thing that
        // happened. It is one copy pressed again, and hanging a second card
        // for it fills the line with copies of one colour because a key was
        // hit twice.
        //
        // Strictly consecutive: the same thing as the last thing copied. The
        // same thing again after something else in between is a return rather
        // than a repeat, and gets its own card.
        if let previous = items.first(where: { !$0.falling }),
           previous.payload == payload {
            return nil
        }
        var item = Pegged(payload: payload, origin: origin, thumb: thumb(for: payload), rich: rich)
        item.flying = flying
        // Newest first, everywhere: the attic, the line and the view all
        // read the same way round, so there is one order to remember.
        items.insert(item, at: 0)
        // A new copy is what you want to look at, so the line comes back to
        // it rather than staying wherever it was panned to, and whatever was
        // open on the line closes: the copy is the end of the choosing.
        //
        // The search closes with it, but keeps its word. A search that is
        // still in force when the new thing arrives would hide it — and the
        // one card that just arrived is the card the user most wants to see.
        // Closing the field while leaving the word would hide it just the
        // same, so the word goes too: the filter's segments do the same thing
        // and a line can only be looking at one thing at a time.
        NotificationCenter.default.post(name: .filterCollapsed, object: nil)
        if !activeQuery.isEmpty { SearchController.shared.close() }
        panToNewest()
        // Nothing is pushed off the line any more. It used to let the oldest
        // card fall when the line was full, but a card leaving the line is now
        // a card leaving the history — so the line stayed short and the attic
        // stayed empty, which is the opposite of what the attic is for. The
        // line shows what fits and the rest is panned to.
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// Convenience for the screenshot path, which still works exactly as it
    /// did: a file on disk becomes a card.
    @discardableResult
    func hang(url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        hang(.image(url), quietly: quietly, flying: flying)
    }

    /// A thumbnail, for the kinds that have one. A picture shows itself —
    /// that is the whole difference between a picture card and a file card.
    /// A file card is an icon and a name drawn by the view, so asking for a
    /// thumbnail of it would read the whole document to render a picture of
    /// its first page, and a rule with one exception is a rule nobody can
    /// hold in their head: a file hangs as a file, however much a picture it
    /// also is.
    private func thumb(for payload: Payload) -> NSImage? {
        guard let url = payload.imageURL else { return nil }
        return makeThumbnail(url)
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        // Taking a card off the line is taking it out of the history too. If
        // it only left the line, it would come back on the next launch, and a
        // cross that does not delete anything is worse than no cross.
        forget(items[i].payload)
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// Removes a payload from the attic.
    private func forget(_ payload: Payload) {
        let entries = attic.entries.filter { $0.payload != payload }
        guard entries.count != attic.entries.count else { return }
        attic.save(entries)
    }

    /// "Take everything down": every card on the line goes the way of its
    /// corner cross.
    ///
    /// Whatever deck is up, which is what makes the menu item mean the same
    /// thing on both: `discard` is the one place that knows a note is not a
    /// copy, and this hands everything on the line to it rather than deciding
    /// for itself what taking something down involves.
    func clear() {
        let live = onLine.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0)
            }
        }
    }

    /// The same, for one rope only: every card of the named deck comes down,
    /// whatever is showing. Where "take it all down" lives now — in the
    /// settings, where the choice of which rope can be made deliberately,
    /// rather than in a menu that took whatever was on screen at the time.
    ///
    /// Pinned cards stay. A clear that reached past the pin would make the
    /// pin a decoration: the cross respects it, the retention window
    /// respects it, and the wide gesture does not get to be the exception.
    func clear(deck: Line.Deck) {
        let live = onLine.filter { !$0.falling && !$0.pinned && $0.payload.isNote == (deck == .notes) }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0)
            }
        }
    }

    /// Items whose file was deleted or moved away fall off by themselves.
    /// Text has no file, so it stays.
    /// Opens the file. Text has no file to open, so it goes where the user is
    /// working: on the pasteboard, and pasted into the app they were last in.
    ///
    /// A paste rather than a drag, because a drag is not how an app on
    /// Chromium takes text. Flyring found the same and its clipboard only
    /// ever pasted as well.
    /// A double-click is the way to use a card rather than look at it, and it
    /// means the same thing whatever the card holds: put it on the pasteboard
    /// and paste it into the app the user was last in.
    ///
    /// It used to differ by kind — a picture opened in a viewer, a file in
    /// whatever opens that kind — which made the same gesture mean three
    /// different things and left the most useful one, pasting into wherever
    /// the user was working, only on text. A card is on a line of things you
    /// copied in order to use somewhere, and using it is the same gesture
    /// whatever it is: a picture pastes into a document, a file pastes into
    /// a mail message, a folder pastes into a Finder window.
    ///
    /// The magnifier in the corner is the other half and does not overlap
    /// with this: that one looks before you commit.
    func open(_ id: UUID) {
        paste(id)
    }


    func prune() {
        for item in items where !item.falling {
            guard let url = item.url else { continue }
            // Only the pictures this app wrote are its to clean up. A file
            // card is a reference to something the user owns: it is dropped
            // if the file is gone, never trashed if it is there.
            if !FileManager.default.fileExists(atPath: url.path) { drop(item.id, quietly: true) }
        }
    }

    /// Takes down every card whose file has gone, at one ask. The grey that
    /// says a file is missing is on a card the user has already answered
    /// about — they saw the grey, chose this, and the cards come down one
    /// after another the way a clear does. A card whose file is gone has
    /// nothing to trash, so these are drops, not discards.
    func discardMissing() {
        let gone = onLine.filter { item in
            guard !item.falling, !item.payload.files.isEmpty else { return false }
            return item.payload.files.contains { !FileManager.default.fileExists(atPath: $0.path) }
        }
        for (n, item) in gone.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    // MARK: Actions on one item

    /// Puts the card on the pasteboard, and says so while it is there.
    ///
    /// The tick under the card is the only confirmation this app gives, and it
    /// is worth giving: a press that copies looks exactly like a press that
    /// missed, and the pasteboard says nothing about which happened. It goes
    /// away on its own after a moment rather than waiting to be told, so a
    /// second copy replaces it rather than leaving two.
    /// - Parameter formatted: `nil` asks the copy-with-formatting switch,
    ///   which is what a click and a double click mean; `true` and `false`
    ///   are the right-click menu's two copy items, which answer to nobody.
    func copy(_ id: UUID, formatted: Bool? = nil) {
        // Either deck, because either card can be pressed. A press on a note
        // puts the note's own lines on the pasteboard — with the ticks spelled
        // out, so what lands somewhere else is the list as it reads and not a
        // list nobody has started.
        guard let item = onLine.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        switch item.payload {
        case .image(let url):
            if let png = pngData(url) { entry.setData(png, forType: .png) }
            entry.setString(url.absoluteString, forType: .fileURL)
        case .file(let urls):
            // The files themselves, not copies of them: what the user copied
            // is a reference to somewhere, and putting the references back is
            // what they copied in the first place. One line per file, which
            // is what the pasteboard means by the type.
            entry.setString(urls.map(\.absoluteString).joined(separator: "\n"),
                            forType: .fileURL)
        case .text(let string, _):
            entry.setString(string, forType: .string)
            // The words first, then the dressing when it is wanted: the two
            // ride on the same item, and the target asks for the one it
            // wants — a terminal takes the words and never sees the rest.
            if (formatted ?? FormatCopy.isEnabled), let rich = item.rich {
                rich.write(to: entry)
            }
        case .note(let note):
            entry.setString(note.plainText, forType: .string)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Marked as ours so the watcher knows this change is this app's and
        // does not hang a card of something already on the line.
        entry.setString("1", forType: ClipboardWatcher.ourWrite)
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    /// Puts a card into the app the user was last working in.
    ///
    /// Falls back to the pasteboard when there is nowhere to paste: the text
    /// is still on it, and ⌘V will do the rest.
    @discardableResult
    func paste(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        if PasteInto.shared.paste(item.payload, rich: item.rich) { return true }
        copy(id)
        return false
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id }), let url = item.url else { return false }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            log.notice("Trashed \(url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Clothespeg's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are. Text has
    /// no file, so it never counts as one.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }), let url = item.url else { return false }
        return Inbox.contains(url)
    }

    /// The corner cross and "Take down" both end up here.
    ///
    /// A note goes by a road of its own, and the reason is the second store.
    /// Taking a card down is a question of which of two things to touch: the
    /// entry in the history that puts it back on the next launch, and the file
    /// on disk if there is one. A note has neither. It is in `Notes.json` and
    /// nowhere else, and taking it down is the note ceasing to exist — which
    /// is why it does not go through `drop` and `forget`, whose whole business
    /// is the history a note is not in.
    func discard(_ id: UUID, quietly: Bool = false) {
        // A pinned card is asked about before it goes. Hiding the cross was
        // tried and was worse: unpinning to find the card again is a hunt,
        // and a way out nobody can find is no way out. So the cross stays
        // where it always is, and the pin is honoured with one question —
        // one press to mean it, one to be sure.
        if !quietly, let item = onLine.first(where: { $0.id == id }), item.pinned {
            confirmPinnedDiscard(item)
            return
        }
        if onLine.first(where: { $0.id == id })?.payload.isNote == true {
            removeNote(id, quietly: quietly)
            return
        }
        if isInInbox(id) { trash(id, quietly: quietly) } else { drop(id, quietly: quietly) }
    }

    /// The question a pinned cross asks. Written like the settings' own
    /// confirmations: what is being lost said plainly, the destructive
    /// answer first, and a modal so the answer comes before anything else.
    /// What "lost" means is the card's own business — a picture takes its
    /// copy to the Trash, a file leaves the original alone, and a note is
    /// the one thing nowhere else.
    private func confirmPinnedDiscard(_ item: Pegged) {
        let alert = NSAlert()
        alert.messageText = L("Delete this pinned card?")
        if let url = item.url, Inbox.contains(url) {
            alert.informativeText = L("The card is pinned — you asked to keep it. Its copy in the app's folder goes to the Trash with it.")
        } else if item.payload.isNote {
            alert.informativeText = L("The note is pinned — you asked to keep it. A note taken down is gone for good.")
        } else {
            alert.informativeText = L("The card is pinned — you asked to keep it. The original file is not touched.")
        }
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Keep them"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            discard(item.id, quietly: true)
        }
    }

    /// Keep an image by copying it to the Desktop. The card stays on the
    /// line: saving is not taking down — whether a card leaves is always
    /// the user's call, made with the cross in the corner.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard let url = item.url else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press and the menu's "标注": the system Markup editor for a card
    /// that has a file an editor can open — a picture, or a file that is a
    /// picture or a PDF. Everything else answers with a copy: the long press
    /// has to do something, and putting the thing back on the pasteboard is
    /// what the hand was most likely after. This is what the item always
    /// claimed to be, rather than a copy wearing its name.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.payload.isNote,
              let url = item.url, Markup.canEdit(url) else {
            copy(id)
            return
        }
        Markup.shared.edit(url)
    }

    /// A link, in the browser: the one honest "open" a text card can offer,
    /// since a snippet has no file to hand to an app.
    func openInBrowser(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              let text = item.payload.captionText,
              let url = URL(string: text), url.scheme != nil else { return }
        NSWorkspace.shared.open(url)
    }

    /// A snippet, on the Desktop as a `.txt` — the image card's "Save to
    /// Desktop", borrowed for the one kind of card that has no file yet. The
    /// card stays: nothing was moved, something was made. The name is the
    /// first line of the snippet, trimmed to something a Finder row can wear.
    func saveTextToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              let text = item.payload.captionText else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        var name = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        for forbidden in ["/", ":", "\0"] { name = name.replacingOccurrences(of: forbidden, with: "-") }
        if name.count > 24 { name = String(name.prefix(24)) }
        if name.isEmpty { name = "Snippet" }
        let target = uniqueURL(in: desktop, for: name + ".txt")
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            log.error("Could not save the snippet to the Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Shows the file in the Finder. Text goes back to the pasteboard.
    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { copy(id) }
    }

    /// Whether a card is watched, asked at menu time rather than carried by
    /// the view: the menu is built when the right click lands, and the answer
    /// it gives has to be the answer for the card as it stands now.
    func isPinned(_ id: UUID) -> Bool {
        items.first(where: { $0.id == id })?.pinned ?? false
    }

    /// Pins a card or lets it go. A pinned card outlives the retention window,
    /// and the pin survives the relaunch with it — which is why this writes
    /// the history now rather than waiting for the next save.
    func setPinned(_ id: UUID, _ on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].pinned != on else { return }
        items[i].pinned = on
        save()
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    /// The line survives a relaunch, and so does everything behind it: the
    /// attic is the store, and the line is rebuilt from it on launch. What is
    /// on the line and what is behind it are the same list, so there is only
    /// one thing to keep up to date.
    private func save() {
        // Both the line and the attic run newest first, so this is a straight
        // copy. Getting that order wrong is why a relaunch once showed the
        // oldest card you had copied, which is the one thing a memory must
        // never do.
        // Each card is its own entry, identified by its own id. Comparing by
        // payload would drop every repeat, which is the thing the line is
        // for now: two copies of the same snippet at two different minutes
        // are two things that happened.
        var entries = items.filter { !$0.falling }
            .map { Attic.Entry(payload: $0.payload, origin: $0.origin, id: $0.id, rich: $0.rich, pinned: $0.pinned) }
        // Anything panned out of sight is still hung, and still comes back.
        let known = Set(entries.map(\.id))
        for entry in attic.entries where !known.contains(entry.id) {
            entries.append(entry)
        }
        attic.save(entries)
    }

    /// Everything comes back as it was, newest first, and the line shows the
    /// newest of it. This runs before the line knows its screen, so nothing
    /// is hung through `hang` and nothing is pushed off the end.
    ///
    /// This is also where the retention window is applied, which is the only
    /// time it is applied at all: a card that was copied a fortnight ago is
    /// not out of date the moment it crosses the line, and nothing is
    /// removed from under the hand that is using it. So the clearing happens
    /// once, at launch, and the rest of the session is left alone.
    private func restore() {
        let kept = sweepNow()
        guard !kept.isEmpty else { return }
        defer { ZoomController.shared.register(contentsOf: items) }
        // The attic is stored newest first, so the line comes back the same way.
        for entry in kept {
            // The stored id comes back with the entry. Minting a new one here
            // made every card a stranger to the history it was restored from,
            // and the next save — which keeps what it does not recognise —
            // appended all of them again. That is why the count doubled on
            // every launch: 164, then 328, then 656.
            items.append(Pegged(id: entry.id, payload: entry.payload,
                                origin: entry.origin, thumb: thumb(for: entry.payload),
                                rich: entry.rich, pinned: entry.pinned ?? false))
        }
    }

    /// Applies the retention window: what is kept, and what is let go.
    ///
    /// Returns what survived, so the caller can put it on the line. Called at
    /// launch and from the settings window, which is why it is not private —
    /// the window offers to clean up on demand, and an offer that does
    /// something other than what the launch does would be a second
    /// implementation of the same rule.
    ///
    /// The cards being let go are put in the Trash rather than deleted, and
    /// only when they are this app's own copies — a picture that came from the
    /// Desktop is not the app's to move.
    ///
    /// All of it is guarded by the history having been readable. A load that
    /// failed returns nothing at all, and "nothing is old enough to keep" and
    /// "the file did not read" are the same empty list — so without the guard,
    /// one unreadable file would empty the pictures folder.
    @discardableResult
    func sweepNow() -> [Attic.Entry] {
        let loaded = attic.load()
        guard !loaded.kept.isEmpty || !loaded.letGo.isEmpty else { return [] }
        guard attic.historyExists() else { return loaded.kept }

        for entry in loaded.letGo {
            guard let url = entry.payload.imageURL, Inbox.contains(url) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                log.notice("Let go \(url.lastPathComponent, privacy: .public) — past \(Attic.retentionDays) days")
            } catch {
                log.error("Could not let go \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // And any picture in the folder that no card is pointing at — left
        // behind by a crash between the picture being written and the history
        // being saved.
        Inbox.sweep(keeping: Set(loaded.kept.compactMap { $0.payload.imageURL }))

        if !loaded.kept.isEmpty { attic.save(loaded.kept) }
        return loaded.kept
    }

    // MARK: Helpers

    /// The one sound this line makes, and the reason it is not private: the
    /// notes half is an extension in a file of its own, and a note coming down
    /// has to sound like a card coming down. Two implementations of one sound
    /// is how the two halves of one line start to sound different.
    func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = 320) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
