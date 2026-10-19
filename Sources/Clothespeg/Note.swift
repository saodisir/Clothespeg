import AppKit
import SwiftUI

/// One line of a note, read back out of the note's own text.
///
/// A note is one string. What is typed is what is stored — marks and all, the
/// way it is in every editor that speaks Markdown — and this is that string,
/// one line at a time, worked out when something asks to draw it or to press
/// it and thrown away again. Nothing here is written down: the text is the
/// note, and a second copy of the note kept beside the first is a second copy
/// that can disagree with it.
struct NoteItem: Equatable {
    /// The words, with the mark taken off the front.
    var text: String
    var kind: Kind
    /// The mark exactly as it was written: "- ", "- [x] ", "3. ".
    ///
    /// Kept rather than worked out again from `kind`, because it is the user's
    /// text and not ours. A line typed "[ ] milk" and later ticked has to come
    /// back as "[x] milk", not as "- [x] milk": the two say the same thing to
    /// the parser and different things to the person who wrote it.
    var mark: String

    enum Kind: Codable, Equatable {
        /// Prose. The first of these, when the first line is one, is the
        /// note's title.
        case text
        /// A list line with nothing to tick: "- milk".
        ///
        /// A bullet rather than an empty box, which is what a bare dash used
        /// to be read as. "- milk" says nothing about milk having to be done,
        /// and a box drawn beside it would be a box with nothing behind it to
        /// tick — so the press would have to write an "[x]" the person never
        /// typed. A mark that means what it says is worth more than one that
        /// saves a keystroke, and "- " meaning "bullet" is what it means
        /// everywhere else.
        case bullet
        /// A thing to do, ticked or not.
        case todo(done: Bool)
        /// A line in a numbered list.
        ///
        /// The number is not stored. It is where the line is that makes it the
        /// third one, the way it is in every list anybody has ever written by
        /// hand — and a stored number is a number that goes wrong the first
        /// time a line above it is deleted.
        case numbered
    }

    var isText: Bool { kind == .text }
    var isBullet: Bool { kind == .bullet }
    var isTodo: Bool { if case .todo = kind { return true }; return false }
    var isNumbered: Bool { kind == .numbered }
    var isDone: Bool { if case .todo(let done) = kind { return done }; return false }

    /// Whether this line is written after a mark, so the words start where the
    /// mark leaves off rather than at the edge of the paper.
    var hasMarker: Bool { !mark.isEmpty }

    /// Whether there is anything on this line worth keeping. A mark with
    /// nothing after it is a line the writer had not got to yet.
    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The inline shape a line can carry, and where it is.
///
/// One reader for the two sides of a note: the editor lays the face over
/// its characters and the card builds its one line of rich text from the
/// same spans, so the two cannot disagree about what `**` means.
///
/// Bold is the whole of it. Italic and code were once read here as well,
/// and were taken out with the buttons that taught them: two faces that
/// read as little more than a smudge at twelve points were a distinction
/// nobody was making twice. There is no escape character and no nesting,
/// because this is a note: `**` is the one shape anybody reaches for, and
/// it is all of them.
enum NoteInline {
    struct Span {
        /// The words the face applies to.
        let inner: NSRange
        /// The delimiters round them, which the card does not draw and the
        /// editor draws faded.
        let delimiters: [NSRange]
    }

    private static let boldExpression = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)

    static func spans(in line: String) -> [Span] {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return boldExpression.matches(in: line, range: full).map { match in
            Span(
                inner: match.range(at: 1),
                delimiters: [NSRange(location: match.range.location, length: 2),
                             NSRange(location: match.range.location + match.range.length - 2, length: 2)])
        }
    }

    /// The line as it is drawn on the card: the words, delimiters off.
    ///
    /// The card is the rendered truth — it takes the list marks off and
    /// draws a square, and the inline delimiters go the same way.
    static func rendered(_ line: String) -> String {
        let ns = line as NSString
        let drops = spans(in: line).flatMap(\.delimiters).sorted { $0.location < $1.location }
        guard !drops.isEmpty else { return line }
        var out = ""
        var cursor = 0
        for drop in drops {
            guard drop.location >= cursor else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: drop.location - cursor))
            cursor = drop.location + drop.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

/// The marks that turn a line into a list line.
///
/// Markdown's, near enough: the shapes anybody already knows. What is
/// different from a moment ago is that the mark is no longer eaten as it is
/// typed. It stays in the text and is read back out of it, because the text is
/// what the note is — and an editor that rewrote what you typed in the same
/// keystroke is an editor you cannot type in.
enum NoteMark {
    struct Match {
        var kind: NoteItem.Kind
        /// The mark, as it was written.
        var mark: String
    }

    /// A tick box, in the shapes anybody types. Tried before the bare dash and
    /// in this order, because "- [ ] " starts with "- " as well and would
    /// otherwise be read as a bullet with the brackets left in the words.
    private static let tickBoxes = ["- [x] ", "- [X] ", "- [ ] ", "[x] ", "[X] ", "[ ] ", "[] "]

    static func match(_ line: String) -> Match? {
        for shape in tickBoxes where line.hasPrefix(shape) {
            let done = shape.contains("x") || shape.contains("X")
            return Match(kind: .todo(done: done), mark: shape)
        }
        // A bullet. What most people reach for first.
        for shape in ["- ", "* ", "+ "] where line.hasPrefix(shape) {
            return Match(kind: .bullet, mark: shape)
        }
        // "1. " or "1) ". The number is thrown away rather than kept: see
        // `NoteItem.Kind.numbered`.
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return Match(kind: .numbered, mark: String(line.prefix(digits.count + 2)))
    }

    /// The line, taken apart.
    static func parse(_ line: String) -> NoteItem {
        guard let match = match(line) else {
            return NoteItem(text: line, kind: .text, mark: "")
        }
        return NoteItem(text: String(line.dropFirst(match.mark.count)),
                        kind: match.kind,
                        mark: match.mark)
    }

    /// The mark the next line of the same list starts with.
    ///
    /// Read off the line above rather than worked out again from the kind, so
    /// that a list carries on in the shape it was started in: "- " stays "- ",
    /// "1) " stays "1) ", and a box that was ticked comes back unticked.
    static func continued(_ item: NoteItem) -> String {
        switch item.kind {
        case .text:
            return ""
        case .bullet:
            return item.mark
        case .todo:
            // Never a done one: the next thing to do is not already done.
            var mark = item.mark
            for spelled in ["[x]", "[X]", "[]"] {
                mark = mark.replacingOccurrences(of: spelled, with: "[ ]")
            }
            return mark
        case .numbered:
            let digits = item.mark.prefix { $0.isNumber }
            let separator = item.mark.dropFirst(digits.count)
            return "\((Int(digits) ?? 1) + 1)\(separator)"
        }
    }

    /// The line with its tick flipped, or nil when it has no tick to flip.
    ///
    /// The mark is edited where it stands rather than written out again, so
    /// that ticking a line does not quietly respell it — see `NoteItem.mark`.
    static func flipped(_ line: String) -> String? {
        let item = parse(line)
        guard case .todo(let done) = item.kind else { return nil }
        var mark = item.mark
        for spelled in (done ? ["[x]", "[X]"] : ["[ ]", "[]"]) {
            mark = mark.replacingOccurrences(of: spelled, with: done ? "[ ]" : "[x]")
        }
        return mark + item.text
    }
}

/// What a note is: a few lines, in the order they were written.
///
/// The order is the note. There is nothing to sort by and nothing to drag,
/// which is not a missing feature — a list of five things you typed this
/// morning is already in the only order that means anything.
struct Note: Equatable {
    /// The whole note, and the only copy of it.
    ///
    /// One string. The marks are in here and the words are in here, and
    /// `items` is this read back a line at a time. What was typed is what is
    /// stored, which is what makes the editor one text view instead of a stack
    /// of fields — and one buffer is the only thing a selection, ⌘Z and the up
    /// and down keys can move through.
    var text: String = ""

    /// The wash over that paper, when the note has one. Same rules as the
    /// paper: nil follows the default, a picked wash is kept like the words
    /// are kept.
    var tint: NoteTint? = nil

    /// When this note's reminder was set to ring.
    ///
    /// Three optional fields rather than one wrapped one, because a note
    /// without a reminder is the common case and the file says so by their
    /// absence — the same rule `tint` keeps. For a repeating reminder this
    /// is the anchor it was set from, and the next ring is worked out from
    /// it; see `reminderOccurrence(after:)`.
    var remindAt: Date? = nil

    /// How the reminder comes back: every day, every week, every month. Nil
    /// for one that rings once. The week and the month are read off
    /// `remindAt` — a reminder set for a Wednesday and repeated weekly is
    /// every Wednesday, not a second question to answer.
    var remindRule: RepeatRule? = nil

    /// Whether a one-time reminder has rung and not been cleared yet. A
    /// repeated one never carries this: it has no "after" to be in.
    var remindFired: Bool = false

    enum RepeatRule: String, Codable, CaseIterable, Identifiable {
        case daily, weekly, monthly

        var id: String { rawValue }
    }

    /// The note, one line at a time.
    ///
    /// Worked out on every ask rather than kept beside the text, so that there
    /// is one copy of a note and not two that can drift apart. A note is at
    /// most a screenful of lines, so this is a handful of string comparisons.
    var items: [NoteItem] {
        text.components(separatedBy: "\n").map(NoteMark.parse)
    }

    /// Whether there is anything here worth keeping. A note of blank lines is
    /// not a note, and hanging one would put an empty card on the line that
    /// nothing can be done with.
    var isBlank: Bool { items.allSatisfy(\.isBlank) }

    /// The prose line at the top, when the top line is prose.
    var titleItem: NoteItem? {
        guard let first = items.first, first.kind == .text else { return nil }
        return first
    }

    /// Everything under the title, or everything when there is no title.
    var bodyItems: [NoteItem] {
        titleItem == nil ? items : Array(items.dropFirst())
    }

    var todos: [NoteItem] { items.filter(\.isTodo) }
    var doneCount: Int { todos.filter(\.isDone).count }

    /// Whether every line that can be ticked has been.
    ///
    /// False for a note with nothing to tick. A note that was never a list has
    /// not been finished; it is a note, and saying it was finished would draw
    /// it faded for the rest of its life.
    var isAllDone: Bool { !todos.isEmpty && doneCount == todos.count }

    /// What goes on the pasteboard: the text, as it stands.
    ///
    /// Not respelled on the way out. The marks in the text are the marks that
    /// are in the text — "- [ ] milk" is copied as "- [ ] milk" — because the
    /// note is its text, and an export that quietly rewrote it would be a
    /// second version of the note to keep in step with the first.
    var plainText: String { text }

    /// What gets saved: the text as it was written, each line only relieved
    /// of the spaces the caret left behind.
    ///
    /// Blank lines stay. A return is a return — the writer pressed it to part
    /// two lines of text, and the card draws it the same way: a row of paper
    /// where the words are not, which is the gap the press was asking for.
    /// Taking those lines was tried and was the wrong answer: a return that
    /// vanishes between the editor and the card reads as the app having lost
    /// it, and the card stopped being the note that was typed.
    var tidied: Note {
        let kept = text.components(separatedBy: "\n").map { line -> String in
            // Trailing spaces go too: they are the caret having been there.
            var trimmed = line
            while let last = trimmed.last, last == " " || last == "\t" { trimmed.removeLast() }
            return trimmed
        }
        // The reminder rides along: tidying the words is not the user asking
        // to be unreminded.
        return Note(text: kept.joined(separator: "\n"), tint: tint,
                    remindAt: remindAt, remindRule: remindRule, remindFired: remindFired)
    }

    /// The note with the tick on one line flipped, or nil when that line has
    /// no tick to flip. This is the whole of what a press on a card's square
    /// does.
    ///
    /// One line is rewritten and the rest of the text is handed back exactly
    /// as it was, so ticking something cannot disturb what is around it.
    func toggling(lineAt index: Int) -> Note? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index),
              let flipped = NoteMark.flipped(lines[index]) else { return nil }
        lines[index] = flipped
        // A tick is a change to the words, not to the reminder: it rides along.
        return Note(text: lines.joined(separator: "\n"), tint: tint,
                    remindAt: remindAt, remindRule: remindRule, remindFired: remindFired)
    }
}

extension Note: Codable {
    /// What a note was before it was one string.
    ///
    /// A note used to be stored as a list of lines, each with its own kind
    /// kept beside it. There are notes in the file on this machine written
    /// that way, and losing them because the shape changed would be the app
    /// dropping the only copy of something somebody wrote down to keep — which
    /// is the exact thing this whole feature is arranged to prevent. So the
    /// old shape is still read, and written out again in the new one.
    private struct Written: Decodable {
        var text: String?
        var items: [WrittenLine]?
        var tint: NoteTint?

        private enum CodingKeys: String, CodingKey { case text, items, tint }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            items = try container.decodeIfPresent([WrittenLine].self, forKey: .items)
            // A tint the reader does not know is a colour that no longer
            // exists; it is read as no wash rather than allowed to fail the
            // note, because the file was written by a version of this app
            // and the note in it outlives any one spelling of a colour.
            let rawTint = try? container.decodeIfPresent(String.self, forKey: .tint)
            tint = rawTint.flatMap { $0 }.flatMap(NoteTint.init(rawValue:))
        }
    }

    private struct WrittenLine: Decodable {
        var text: String
        var kind: NoteItem.Kind
    }

    private enum CodingKeys: String, CodingKey {
        case text, tint, remindAt, remindRule, remindFired
    }

    init(from decoder: Decoder) throws {
        let written = try Written(from: decoder)
        if let text = written.text {
            self.text = text
        } else if let items = written.items {
            self.text = Note.rewritten(items)
        } else {
            self.text = ""
        }
        self.tint = written.tint
        // A field the reader does not know is a field that was not there
        // when the file was written — the notes of every version before the
        // reminder lived here have none, and an unreadable one is read as
        // none rather than allowed to fail the note.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.remindAt = try? container.decodeIfPresent(Date.self, forKey: .remindAt)
        self.remindRule = (try? container.decodeIfPresent(RepeatRule.self, forKey: .remindRule)) ?? nil
        self.remindFired = (try? container.decodeIfPresent(Bool.self, forKey: .remindFired)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        // Written only when there is one: a note that follows the line's
        // choice keeps following it when the choice changes, and the file
        // does not grow a field for the notes that never picked.
        try container.encodeIfPresent(tint, forKey: .tint)
        // The reminder the same way: a note without one writes nothing.
        try container.encodeIfPresent(remindAt, forKey: .remindAt)
        try container.encodeIfPresent(remindRule, forKey: .remindRule)
        if remindFired {
            try container.encode(true, forKey: .remindFired)
        }
    }

    /// The old list of lines, as one string.
    private static func rewritten(_ items: [WrittenLine]) -> String {
        var run = 0
        return items.map { item -> String in
            switch item.kind {
            case .numbered:
                run += 1
                return "\(run). " + item.text
            case .todo(let done):
                run = 0
                return (done ? "- [x] " : "- [ ] ") + item.text
            case .bullet:
                run = 0
                return "- " + item.text
            case .text:
                run = 0
                return item.text
            }
        }.joined(separator: "\n")
    }
}

/// Where the lines of a note go on its card.
///
/// Written once and read twice. The card draws from it and the press that
/// ticks a box hit-tests against it, and if those were two pieces of
/// arithmetic about the same rows they would eventually disagree — a tick that
/// lands on the row above the one under the pointer is a bug nobody can see
/// the cause of.
///
/// All of it is in the card's own coordinates: the origin is the top left of
/// the paper, and y runs down.
enum NoteCardLayout {
    /// Wider than everything else on the line, and the one place where the two
    /// halves stop looking alike.
    ///
    /// A picture and a snippet are a few words or a thumbnail, and 150 points
    /// holds both. A note is written in sentences: at 150 a line of them is
    /// cut off in the middle of the fourth word, and a card that has to be
    /// clicked to be read is not something you can leave hanging there and
    /// glance at, which is the whole reason the notes are on this line.
    ///
    /// So the notes have their own pitch as well as their own width — see
    /// `Layout.pitch(for:)`. Nothing has to be shared: the two decks are never
    /// on the rope together.
    static let width: CGFloat = 210

    /// A short note is short, and a long one stops here.
    ///
    /// Much deeper than a snippet's card, and again because of what a note is.
    /// The ceiling is not a preference: the panel is only so deep, the rope
    /// sits about forty into it once it has sagged, and the clip takes
    /// fourteen more, so a card taller than the room left under it is clipped
    /// — and a clipped card looks like a bug rather than a long note. Since
    /// this card is allowed to grow, the panel grows with it; see
    /// `Layout.depth(for:)`.
    static let maxHeight: CGFloat = 236
    /// A card with one line on it still has to read as a card rather than as
    /// a slip of paper.
    static let minHeight: CGFloat = 70

    static let sidePad: CGFloat = 10
    /// Deeper than the bottom on purpose. The card's two top corners belong to
    /// the cross and the pencil, twenty-six points each, and a line drawn at
    /// the very top would put its tick box underneath the cross — so pressing
    /// the first box would throw the note away.
    ///
    /// Twenty-six and not twenty. Twenty cleared the *drawing* of the cross,
    /// which is what it was worked out from, and left the first line's tick
    /// sitting under the last six points of the cross's target — so the top
    /// sliver of the first box threw the note away instead of ticking it, and
    /// only that sliver: the same box ticked perfectly well a few points
    /// lower. A tick that works or does not depending on where in the square
    /// you hit is the worst version of this, because nothing about it is
    /// visible from the outside. Now the first line starts below the whole of
    /// the corner, and every press in the first box is a tick.
    static let topPad: CGFloat = 26
    static let bottomPad: CGFloat = 10
    static let rowHeight: CGFloat = 16
    static let captionHeight: CGFloat = 18
    static let boxSize: CGFloat = 9.5
    static let boxGap: CGFloat = 5
    /// The room a mark gets before the words start, whether the mark is a box,
    /// a bullet or a number.
    ///
    /// One column for all of them, so that a list of bullets, a list of ticks
    /// and a list of numbers start their words in the same place. More than
    /// one width would be more than one indent on one card, which reads as a
    /// mistake rather than as several kinds of list.
    static let markerColumn: CGFloat = 20

    struct Row {
        /// Which line of the note this is. Every line has a row now — the
        /// ones past the ceiling live in the card's scroll rather than in
        /// nothing at all.
        let index: Int
        let rect: CGRect
        /// Where this line can be ticked, when it can be. A press inside it
        /// ticks the line; a press anywhere else on the card does what a press
        /// on a card does. Always nil for prose, bullets and numbers, which is
        /// what makes a press on any of those mean the card rather than the
        /// line.
        ///
        /// A target rather than a drawing: it is the whole marker column and
        /// the whole row, where the square inside it is nine points across.
        /// The square is drawn by the view; this is what the press is tested
        /// against.
        let box: CGRect?
        /// The number this line is drawn with, when it is a numbered one.
        /// Nothing is pressed here: a number is a label, and the only line on
        /// a card that can be pressed is one with a box.
        let number: Int?
        /// Whether this line is a bullet, which is drawn rather than pressed.
        let bullet: Bool
        /// How many lines of paper this row takes, which the row's height is
        /// made of. One, nearly always; more when the words are longer than
        /// the card is wide.
        let lines: Int

        /// Whether this row keeps the mark's column before its words. Read by
        /// the view so that a line of prose and a line of list start in the
        /// two different places the layout says they do.
        var hasMarker: Bool { box != nil || number != nil || bullet }
    }

    struct Arrangement {
        var rows: [Row] = []
        /// The note's lines, parsed once here so that the view does not parse
        /// the same text again for every row it draws.
        var items: [NoteItem] = []
        /// The card's height: what the contents take, capped at `maxHeight`.
        var height: CGFloat = NoteCardLayout.minHeight
        /// What the contents would take with no ceiling at all. The distance
        /// between this and `height` is the card's scroll — the room the
        /// rows beyond the ceiling live in.
        var fullHeight: CGFloat = NoteCardLayout.minHeight
    }

    static func arrange(_ note: Note) -> Arrangement {
        let items = note.items
        let hasTitle = items.first?.kind == .text

        var arrangement = Arrangement()
        arrangement.items = items
        var y = topPad
        if hasTitle {
            // Measured like any other line. The first line used to be drawn
            // heavier, which is a choice the writer did not make; the bold
            // button is how a line becomes a heading now, on either side of
            // the note and on whichever line the writer says.
            let lines = Self.lines(for: items[0], marker: false, size: 12, weight: .regular)
            let height = max(rowHeight, CGFloat(lines) * rowHeight)
            arrangement.rows.append(Row(
                index: 0,
                rect: CGRect(x: sidePad, y: y, width: width - sidePad * 2, height: height),
                box: nil, number: nil, bullet: false, lines: lines))
            y += height
        }
        // Every line gets its place, whatever the card's ceiling says. The
        // ceiling is the card's, not the note's: the rows past it live in the
        // card's scroll, and a line that is only reachable by scrolling is a
        // line that is still reachable — which is the whole of the promise
        // the old cut-off row could not keep.
        var run = 0
        var index = hasTitle ? 1 : 0
        while index < items.count {
            let item = items[index]
            let lines = Self.lines(for: item, marker: item.hasMarker, size: 12, weight: .regular)
            let height = CGFloat(lines) * rowHeight
            if item.isNumbered { run += 1 } else { run = 0 }
            // The rectangle a press is tested against, which is not the square
            // that is drawn. The square is `boxSize` across; the target is the
            // whole marker column for the height of the row, which is where a
            // hand goes anyway — and the height of the row now includes the
            // lines the words wrap onto, so a press aimed at the second line
            // of a wrapped one ticks the same box.
            //
            // Only where there is something to tick: prose, bullets and
            // numbers have no box, and a box that is drawn but does nothing is
            // worse than no box.
            let box = item.isTodo
                ? CGRect(x: sidePad, y: y + 1,
                         width: markerColumn, height: height - 2)
                : nil
            arrangement.rows.append(Row(
                index: index,
                rect: CGRect(x: sidePad, y: y, width: width - sidePad * 2, height: height),
                box: box,
                number: item.isNumbered ? run : nil,
                bullet: item.isBullet,
                lines: lines))
            y += height
            index += 1
        }

        arrangement.fullHeight = y + captionHeight + bottomPad
        arrangement.height = max(minHeight, min(maxHeight, arrangement.fullHeight))
        return arrangement
    }

    /// How many lines of paper a note's line takes, at the width the card
    /// gives it.
    ///
    /// Measured in the face the row is drawn in, over the words as they are
    /// drawn — delimiters off — with a point of slack, because the measure
    /// and the drawing are two engines that have to agree on where words
    /// break. Capped at three: a line that wraps past three is a paragraph
    /// somebody dropped into a list, and the card is a glance, not a page.
    /// The editor shows the whole of it.
    private static func lines(for item: NoteItem, marker: Bool,
                              size: CGFloat, weight: NSFont.Weight) -> Int {
        let words = NoteInline.rendered(item.text)
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let width = Self.width - Self.sidePad * 2
            - (marker ? Self.markerColumn + Self.boxGap : 0) - 2
        let bound = NSAttributedString(string: words, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin])
        return min(3, max(1, Int(ceil(bound.height / rowHeight))))
    }
}
