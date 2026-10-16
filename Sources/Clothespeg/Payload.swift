import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What hangs on the line.
///
/// Tendedero hung screenshots, so everything about it was a file: the line
/// stored a `url`, every action went through the file system, and the panels
/// asked the Finder whether a given path was a screen recording. Clothespeg
/// hangs whatever was copied, so a pegged item is content first and a file
/// only when it really is one.
///
/// Cases, deliberately:
/// - `.image` keeps a URL, because a picture dragged into another app has to
///   come from somewhere on disk.
/// - `.text` keeps the string itself. A copied snippet has no file, and
///   inventing one would leave the user with a folder of orphan files.
/// - `.note` keeps the note itself, for a stronger reason than `.text` has:
///   nothing outside this app ever produced it. A copy is a picture of
///   something that already exists elsewhere; a note exists here and nowhere
///   else, so this is where it lives and `Notes.json` is the only copy.
///
/// A note is the one thing on the line that was not copied. It is not reached
/// by the watcher, it is not kept by the history's window, and it is not on
/// the line for a moment — which is why it is a case of its own rather than
/// text with a flag on it.
enum Payload: Codable, Equatable {
    case image(URL)
    case text(String, isCode: Bool)
    /// Files copied in the Finder, or from any app that offers them. They
    /// are kept as references to where the files already are rather than as
    /// copies: a copy has to be written, named, kept and cleaned up, and it
    /// goes stale the moment the original is edited or moved. References drag
    /// out as the files themselves, which is what every target wants, and
    /// they reflect whatever the files have become since.
    ///
    /// One card for the whole selection, because the selection is the thing
    /// that was copied. Twenty cards for twenty files would fill the line
    /// with one act, and dragging them out together — which is what they are
    /// for — would not be possible.
    case file([URL])
    /// A note that was written here rather than copied from somewhere.
    case note(Note)

    /// A pegged image, or nil when this item is text.
    var imageURL: URL? {
        if case .image(let url) = self { return url }
        return nil
    }

    /// The files this item points at. A picture is a file, and one file is
    /// a list of one, so everything that hands over files has one shape.
    var files: [URL] {
        switch self {
        case .image(let url): return [url]
        case .file(let urls): return urls
        case .text, .note: return []
        }
    }

    /// The first of them, for the places that only need one: the thumbnail,
    /// the icon on the card, the document to preview.
    var fileURL: URL? { files.first }

    /// The note, when this is one.
    var note: Note? {
        if case .note(let note) = self { return note }
        return nil
    }

    /// The string to put back on the pasteboard. Images go as a file URL plus
    /// their PNG, so apps that accept either pick the better one.
    ///
    /// A note goes as its own lines, with the ticks spelled out: a list pasted
    /// somewhere without them reads as a list nobody has started.
    var pasteboardString: String? {
        switch self {
        case .text(let string, _): return string
        case .image(let url): return url.absoluteString
        case .file(let urls): return urls.map(\.absoluteString).joined(separator: "\n")
        case .note(let note): return note.plainText
        }
    }

    /// The colour this text names, if it names one.
    ///
    /// Read strictly on purpose. `#fff` is a colour and `#define` is not, and
    /// a card that mistook a preprocessor line for a colour would come up
    /// black behind code, which is worse than not recognising anything. So
    /// only the three shapes that cannot be anything else are taken: a hex
    /// with three or six digits, and a `rgb()` with three numbers. A name
    /// like `red` is left alone — there are twenty ways to spell one and
    /// several that mean different things in different languages.
    ///
    /// A note is never a colour, however much `#fff` it happens to contain.
    /// The guessing is for what somebody else wrote and this app then had to
    /// decide about; a note is what the person using the app wrote, and being
    /// told that a line of it is a colour would be the app second-guessing
    /// itself.
    var colorValue: (hex: String, color: Color)? {
        guard case .text(let string, _) = self else { return nil }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 40, !text.contains("\n") else { return nil }

        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            guard digits.allSatisfy(\.isHexDigit),
                  digits.count == 3 || digits.count == 6 else { return nil }
            let expanded = digits.count == 3
                ? digits.map { String(repeating: $0, count: 2) }.joined()
                : digits
            guard let value = UInt32(expanded, radix: 16) else { return nil }
            return (text, Color(.sRGB,
                                red: Double((value >> 16) & 0xFF) / 255,
                                green: Double((value >> 8) & 0xFF) / 255,
                                blue: Double(value & 0xFF) / 255,
                                opacity: 1))
        }

        let lower = text.lowercased()
        guard lower.hasPrefix("rgb("), lower.hasSuffix(")") else { return nil }
        let inside = String(lower.dropFirst(4).dropLast())
        let parts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        // Values over 255 are a mistake in the text, not a colour to show.
        let values = parts.compactMap { Int($0) }
        guard values.count == 3, values.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
        return (text, Color(.sRGB,
                            red: Double(values[0]) / 255,
                            green: Double(values[1]) / 255,
                            blue: Double(values[2]) / 255,
                            opacity: 1))
    }

    /// The text a caption refers to, or nil for a picture.
    ///
    /// Nil for a note as well, though there is certainly text in it. What a
    /// caption says is where a card came from and when, and a note came from
    /// nowhere — so its card carries the time alone, drawn by the note's own
    /// view rather than assembled here.
    var captionText: String? {
        switch self {
        case .text(let string, _): return string
        case .image, .file, .note: return nil
        }
    }

    var isImage: Bool { imageURL != nil }
    var isFile: Bool { if case .file = self { return true }; return false }
    var isNote: Bool { if case .note = self { return true }; return false }
}

/// The rich formatting a copy arrived with, kept beside the plain text.
///
/// A copy off a web page or a document carries its dressing on the
/// pasteboard whether anyone asks for it or not: the same words as plain
/// text, and the way they were laid out as RTF or HTML beside them. The
/// watcher reads the words first — they are what the copy is — and this is
/// what was read second, so a card can put the dressing back when the user
/// wants it.
///
/// Captured for every text copy from the day it ships, whichever way the
/// setting is turned: the choice is read when a card goes out, never when it
/// arrives, so turning it on later dresses up the cards already hanging too.
/// A plain-text habit costs nothing but a few bytes in the history.
struct RichText: Codable, Equatable {
    /// RTF, when the source offered it. Pages, TextEdit and mail do.
    var rtf: Data?
    /// HTML, when the source offered that instead. Browsers and chat apps do,
    /// and a source may carry both — the target asks for whichever it prefers.
    var html: String?

    /// Two megabytes. A dressing this large is a paste, not a snippet, and
    /// the words beneath it are already capped at their own ceiling.
    static let maxBytes = 2 * 1024 * 1024

    /// Whatever formatting the pasteboard carries, or nil for a plain copy.
    static func from(pasteboard pb: NSPasteboard) -> RichText? {
        let rtf = pb.data(forType: .rtf)
        let html = pb.string(forType: .html)
        guard rtf != nil || html != nil else { return nil }
        // An oversized dressing is dropped rather than kept in halves: RTF
        // past the ceiling leaves the HTML, which is smaller than a picture
        // and still lays the words out.
        if let rtf, rtf.count > maxBytes {
            return html.map { RichText(rtf: nil, html: $0) }
        }
        return RichText(rtf: rtf, html: html)
    }

    /// Whether there is nothing here to put back.
    var isEmpty: Bool { rtf == nil && html == nil }

    /// Puts the formatting on a pasteboard item that already carries the
    /// plain text. Every flavour rides on the same item: the target asks for
    /// the one it wants, and a target that wants characters — a terminal, an
    /// editor — never sees any of this.
    func write(to item: NSPasteboardItem) {
        if let rtf { item.setData(rtf, forType: .rtf) }
        if let html, let data = html.data(using: .utf8) { item.setData(data, forType: .html) }
    }
}

/// Where a copy came from.
///
/// A snippet on the line is thirty seconds old at most, and after that the
/// source is the part you cannot work out: the same three lines came from a
/// chat, a document and a terminal today.
///
/// NSPasteboard will not say whose copy it was — there is no public API for
/// it — so this is the app that was in front when the change count moved,
/// which is the one the user was copying from.
///
/// A note has no `app` and never will, so the field is left empty and the
/// time carries the line alone. For a note the time means something different
/// from what it means for a copy: not when it arrived, but when it was last
/// written in.
struct Origin: Codable, Equatable {
    /// The app's display name, e.g. "WorkBuddy". Nil when it cannot be told.
    var app: String?
    var at: Date = Date()

    /// The `app · time · count` line along the bottom of a card, or nil when
    /// there is nothing worth saying. Pictures have no caption: the picture is
    /// the content, and a line of text under it is noise.
    ///
    /// The app name is the part that cannot be worked out by looking at the
    /// snippet, so it is kept and the time goes if only one of the two can
    /// stay. The character count is the first to go: it says how much was
    /// left off, which only matters on a long copy.
    func caption(for payload: Payload, fits width: CGFloat) -> String? {
        guard let text = payload.captionText else { return nil }
        let time = Self.time(at)
        let count = "\(text.count)"

        // The app and the time, which are both worth keeping.
        if let app {
            let line = "\(app) · \(time)"
            if Self.width(of: line) <= width { return line + suffix(count, width: width, after: line) }
            // Too long even without the count: shorten the name in the middle,
            // which keeps the first letters and the last, so it is still the
            // app you recognise.
            let brief = shortened(app, to: width - Self.width(of: " · \(time)"))
            return "\(brief) · \(time)"
        }
        // No app to name — Clothespeg cannot always tell. The time alone is
        // still worth the line.
        return time + suffix(count, width: width, after: time)
    }

    /// The time a note was last written in, for the line along its bottom.
    ///
    /// The day as well as the clock, which a copy never needs: a copy is
    /// minutes old and `14:32` places it, while a note can be from any day
    /// this app has been installed and a bare clock would put all of them
    /// today.
    func noteCaption() -> String {
        let clock = Self.time(at)
        guard !Calendar.current.isDateInToday(at) else { return clock }
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: at) + " · " + clock
    }

    /// ` · 142` when the card has room for it after `line`.
    private func suffix(_ count: String, width: CGFloat, after line: String) -> String {
        let together = "\(line) · \(count)"
        return Self.width(of: together) <= width ? " · \(count)" : ""
    }

    /// Trims a string in the middle until it fits, keeping both ends: an app
    /// name is recognised by its first letters and its last as often as by the
    /// middle. A name that already fits is left alone.
    private func shortened(_ string: String, to width: CGFloat) -> String {
        if Self.width(of: string) <= width { return string }
        let characters = Array(string)
        guard characters.count > 4 else { return string }
        // A binary search for the most characters that can be kept at each
        // end. The two halves must not overlap, so the search stops one
        // character short of the whole string.
        var low = 1
        var high = (characters.count - 1) / 2
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(characters.prefix(mid)) + "…" + String(characters.suffix(mid))
            if Self.width(of: candidate) <= width { best = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard best > 0 else { return String(characters.prefix(3)) + "…" }
        return String(characters.prefix(best)) + "…" + String(characters.suffix(best))
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Rough width of a line in the caption face, in points.
    static func width(of string: String) -> CGFloat {
        // 9pt Latin averages about 4.6pt a character and a CJK glyph twice
        // that. Only has to be close enough to decide whether a line fits.
        let columns = string.reduce(0.0) { total, character in
            total + (character.isASCII ? 4.6 : 9.2)
        }
        return CGFloat(columns)
    }
}

/// How a pegged item is drawn. Shared by the card and the drag area, so a
/// drag always matches what the user sees.
enum PayloadCard {
    /// Every card is this wide, picture or text.
    ///
    /// Text was tried narrower, measured to its longest line. It is worse:
    /// cards of two widths on one line do not read as a row of pegs, and a
    /// caption underneath is squeezed by the one under a narrow neighbour.
    /// The pictures vary in height anyway — each keeps its own proportions —
    /// so a fixed width is the shape of the line rather than a rule imposed
    /// on it.
    static let imageWidth: CGFloat = 150
    /// Both kinds stand the same height.
    static let height: CGFloat = 104

    /// How big a card is, which for a note is not a constant.
    ///
    /// A note is the one card whose height is a fact about its contents: five
    /// lines of somebody's morning is not the same shape as one line of it,
    /// and drawing both at 104 would either waste the space under the short
    /// one or hide the end of the long one. Everything else on the line is a
    /// fixed frame with a subject in it, which is why this is the exception.
    ///
    /// Read on every layout rather than cached on the card, for the reason
    /// nothing else here is cached on the card: a card is a value, so a stored
    /// copy is rebuilt on every copy of it, and the arithmetic is a handful of
    /// divisions.
    static func size(of payload: Payload) -> CGSize {
        switch payload {
        case .note(let note):
            return CGSize(width: NoteCardLayout.width,
                          height: NoteCardLayout.arrange(note).height)
        case .image, .text, .file:
            return CGSize(width: imageWidth, height: height)
        }
    }

    /// The card's outside size as the line will draw it: what is inside the
    /// glass plus the frame's inset on each side.
    ///
    /// A picture keeps its own proportions, so its thumbnail decides how tall
    /// it is; everything else is told. Asked in two places — the view that
    /// draws the card and the arithmetic that decides where the pill goes —
    /// and asked here rather than worked out twice, because two answers to
    /// "how deep is this card" is a pill that overlaps the card it was meant
    /// to sit under.
    static func outerSize(of item: Pegged) -> CGSize {
        if let thumb = item.thumb { return PeggedView.cardSize(for: thumb.size) }
        return size(of: item.payload).withInset
    }

    /// The paper a text card is written on.
    ///
    /// A screenshot arrives with its own ground — it is whatever was on the
    /// screen, which is most often light — and the glass simply frames it. A
    /// snippet arrives with nothing, so the card carries the paper itself.
    /// That is the whole difference between the two kinds of card: one has a
    /// subject on a ground, the other is ink on a sheet, and both sit on the
    /// same glass.
    ///
    /// Opaque, because ink needs to know what it is on, and warm by a hair so
    /// it reads as paper rather than as an empty pane of glass.
    ///
    /// Resolved against the appearance rather than written as one colour,
    /// because this is the ground the ink sits on and it has to be the same
    /// kind of thing in both: warm white in the light, warm near-black in the
    /// dark. A fixed value here is what made the card the one part of the app
    /// that did not change when everything else did — the pill went dark and
    /// a sheet of paper stayed sitting on it.
    ///
    /// Dark is not black. A card on a dark background has to be *lighter* than
    /// what is behind it or it stops being a card and becomes a hole; so it is
    /// the same relationship it has in the light, one step up rather than a
    /// different idea.
    static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua:
            NSColor(srgbRed: 0.175, green: 0.170, blue: 0.163, alpha: 1)
        default:
            NSColor(srgbRed: 0.985, green: 0.980, blue: 0.968, alpha: 1)
        }
    })

    /// A line of text wants a monospaced face, and everything else reads
    /// better in the system face. Only the card's font changes, so a wrong
    /// guess costs nothing.
    ///
    /// Thirteen points, and the card is 176 wide to pay for it.
    ///
    /// The two move together on purpose. A point of type at this size is the
    /// difference between reading a card and leaning towards the screen to
    /// read it, and a bigger letter in the same card costs a character a
    /// line — so the card grew as much as the type did, which keeps a line at
    /// twelve characters and spends only the one card a wider row needs.
    static func font(for payload: Payload) -> Font {
        switch payload {
        case .text(_, let isCode):
            return isCode ? .system(size: 12, design: .monospaced) : .system(size: 13)
        case .image, .file, .note:
            return .system(size: 13)
        }
    }

    /// Whether this text reads as a link, so the card can say so.
    static func isLink(_ payload: Payload) -> Bool {
        guard case .text(let string, let isCode) = payload, !isCode,
              let url = URL(string: string),
              url.scheme != nil else { return false }
        return ["http", "https", "ftp", "mailto", "file"].contains(url.scheme?.lowercased() ?? "")
    }
}

extension CGSize {
    /// The card's outside size: what is drawn inside the glass, plus the
    /// frame's inset on every side.
    var withInset: CGSize {
        CGSize(width: width + Frame.inset * 2, height: height + Frame.inset * 2)
    }
}

extension URL {
    /// Whether this file is a picture by its extension. Asked before anything
    /// is read, so a wrong guess costs a type lookup and nothing more.
    var isImageFile: Bool {
        guard let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// The file's size on disk, or zero when it cannot be told. Zero reads as
    /// "not there", which is the answer every caller wants for a file that
    /// has gone.
    var diskBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
    }
}
