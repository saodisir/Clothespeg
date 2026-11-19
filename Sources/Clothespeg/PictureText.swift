import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Reading the words out of a picture.
///
/// A card is searched by what it says, and a picture says nothing this app can
/// read: `Pegged.parts` has the pixels and the path, and a screenshot is
/// therefore findable only by the name it happened to be saved under —
/// `SCR-20261029-0912.png`, which is not what anybody remembers about it.
///
/// This is the common half of that fixed. Most pictures on a line are
/// screenshots, and a screenshot is mostly text, so the words on it are worth
/// as much to the search as the words in a snippet. What it does not do is
/// find a picture by what it *shows* — "the red chart", "the cat" — because
/// that needs a model that knows what a cat looks like, and this one only
/// knows what letters look like.
///
/// Vision rather than bundled weights: it ships with macOS, needs no network,
/// and adds nothing to a 4 MB download. `QRCodes` made the same trade for the
/// same reason, and this follows it down to the thumbnail: a 7680×4320 grab
/// handed to Vision whole takes seconds rather than a moment.
/// One line of words and where it sits on the picture.
///
/// The box is Vision's own: normalised 0…1, bottom-left origin. Keeping it
/// normalised is what lets the same answer survive a backing-scale change
/// between the read and the repaint.
struct TextBlock {
    let text: String
    let box: CGRect
    /// How many visual lines were joined into this block. One is laid out as
    /// a single line; more than one is a paragraph that wraps inside the box.
    let lineCount: Int
}

enum PictureText {
    /// The longest side of the picture that is handed to Vision.
    ///
    /// The code reader's number, reused rather than re-measured: both readers
    /// want the same thing, which is a screenshot small enough to be read in
    /// a moment and large enough that its type survives. See `QRCodes.maxPixel`
    /// for why 1600 and not 800 or 2400.
    static let maxPixel = QRCodes.maxPixel

    /// How much of a picture's text is kept.
    ///
    /// A storage ceiling, not a search one. Every keystroke in the field folds
    /// and compares the parts of every card, and the history is one JSON file
    /// read and written whole — so a screenshot that held an entire document
    /// would cost its full text on every keystroke and every launch. Nothing
    /// anyone searches a screenshot for is on its ninetieth line, and four
    /// thousand characters is a dense page and a half.
    static let maxCharacters = 4000

    /// Every word the picture shows, joined into one string.
    ///
    /// Returns "" when there is nothing to read, rather than taking an
    /// optional. "" is the answer "this was looked at and it holds no words",
    /// which is what stops a picture of a cat being read again on every
    /// launch; the three states live on the card (`Pegged.ocr`), and `nil`
    /// there means "never looked at". `QRCodes` splits them the same way, for
    /// the same reason: two hundred screenshots at a few hundred milliseconds
    /// each is a minute of work nobody asked for twice.
    ///
    /// Blocking, on purpose — the caller puts it on a queue. Accurate
    /// recognition of a screenshot runs to hundreds of milliseconds, which is
    /// invisible behind a card and a visible stutter in front of one.
    static func recognize(in url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "" }
        // The thumbnail rather than the decoded image, the same call the card
        // and the code reader make: the whole picture is never held in memory,
        // whatever its size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return ""
        }
        return recognize(in: image)
    }

    /// The same read, from a picture that is not on disk.
    ///
    /// A capture has its pixels before it has a file — the region is cut out of
    /// the frozen backdrop and read while the overlay is still up, so the person
    /// can be asked whether the reading is worth keeping before anything is
    /// written. Blocking, like its file twin, and for the same reason: accurate
    /// recognition takes hundreds of milliseconds, which is a visible stutter in
    /// front of a question and invisible behind one.
    ///
    /// No thumbnail step: a region dragged out of a screen is already small
    /// enough for Vision, and one that is not is still cheaper to read whole
    /// than to resample twice.
    static func recognize(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        // Accurate rather than fast. Fast is several times quicker and reads
        // Latin type at a glance, but it drops small type and mangles Han
        // characters — and a screenshot is exactly the picture where the words
        // are small and half of them are Chinese. The read is behind a card
        // either way, so the only cost of accurate is a queue that finishes
        // later.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        do {
            try VNImageRequestHandler(cgImage: fitted(image, within: maxPixel), options: [:])
                .perform([request])
        } catch {
            log.error("Text read failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        // Top candidate per line, in the order Vision found them — reading
        // order, which is what makes the joined text look like the picture and
        // not like a bag of words. A line with no candidates is skipped rather
        // than left as a gap.
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return "" }
        return clip(lines.joined(separator: "\n"))
    }

    /// The same read, keeping where each line was.
    ///
    /// `recognize(in:)` throws the boxes away because a search index only wants
    /// the words. A translation that replaces the words on the picture needs
    /// them, and asking Vision twice can read a different set of lines. One
    /// request, two answers. The boxes are normalised, so shrinking the picture
    /// before the read does not move them.
    ///
    /// Wrapped lines are joined into one paragraph before the engine sees
    /// them. Sending each visual line separately is what turned one sentence
    /// into "页面实际上说了什么" and "类型尺寸以适应相同的空间" — two halves
    /// translated as if they were separate thoughts.
    static func recognizeBlocks(in image: CGImage) -> [TextBlock] {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        return paragraphs(joinNeighbours(observations(in: image), aspect: aspect), aspect: aspect)
    }

    /// A box in **square** units: x and width scaled by the picture's aspect, so
    /// every distance is measured against the same denominator.
    ///
    /// Vision normalises x by the width and y by the height, so on a wide strip
    /// one unit of x is five times one unit of y. Every rule here is expressed in
    /// line heights — "a gap under one space", "a gutter wider than 0.8 of a
    /// line" — and comparing those numbers against raw x was the whole of a
    /// misplacement measured on 2026-11-13: on a 2758×539 screenshot the 135-pixel
    /// gutter between two columns is 0.049 of the width and a line is 0.068 of
    /// the height, so the gutter read as *narrower than a word space* and the
    /// card on the left was glued to the headline on the right. The result was
    /// one block whose box spanned both columns: a cover painted as a strip
    /// across the page, and the answer drawn at its left edge.
    private static func square(_ box: CGRect, _ aspect: CGFloat) -> CGRect {
        CGRect(x: box.minX * aspect, y: box.minY,
               width: box.width * aspect, height: box.height)
    }

    /// Every line Vision found, before any grouping.
    ///
    /// Only the probe asks for this. A rule about grouping cannot be judged from
    /// the groups it produced — when a page comes back with its words in the
    /// wrong places, the question is which *raw* boxes were glued together, and
    /// the grouped boxes have already lost that.
    static func rawLines(in image: CGImage) -> [(text: String, box: CGRect)] {
        observations(in: image).map { ($0.text, $0.box) }
    }

    private static func observations(in image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        do {
            try VNImageRequestHandler(cgImage: fitted(image, within: maxPixel), options: [:])
                .perform([request])
        } catch {
            log.error("Block text read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Line(text: trimmed, box: observation.boundingBox)
        }
    }

    private struct Line {
        let text: String
        let box: CGRect
    }

    /// Vision sometimes hands back one line as two observations. Join only the
    /// ones that are truly adjacent: a form's label and its value sit on the
    /// same line a screen apart, and translating them as one sentence would
    /// lose the form.
    ///
    /// **Adjacent means one word space apart and the same size of type.** Both
    /// halves of that were measured on 2026-11-13, on a two-column page that
    /// came back with its words scattered: the old rule allowed a gap of 1.5
    /// line heights, which is five times a space and less than a column gutter,
    /// so a line of body text on the left and a line of a headline on the right
    /// were glued into one "line" — and its box, being a union, spanned both
    /// columns. Everything downstream is then wrong at once: the cover is a
    /// strip across the page (wiping out the other column's words) and the
    /// answer is drawn at the left edge of a box that is two columns wide, which
    /// is the 「错位」 this exists to stop.
    private static func joinNeighbours(_ lines: [Line], aspect: CGFloat) -> [Line] {
        let sorted = lines.sorted {
            if abs($0.box.midY - $1.box.midY) > 0.0001 {
                return $0.box.midY > $1.box.midY
            }
            return $0.box.minX < $1.box.minX
        }
        var joined: [Line] = []
        for line in sorted {
            if let last = joined.indices.last {
                // Measured in square units; the boxes themselves stay in
                // Vision's own coordinates, because that is what the paint uses.
                let before = square(joined[last].box, aspect)
                let now = square(line.box, aspect)
                let smaller = min(before.height, now.height)
                // Same row, measured against the smaller of the two: a 30-point
                // headline and a 16-point line of body never share a row even
                // when their centres nearly line up.
                let sameRow = abs(before.midY - now.midY) < smaller * 0.5
                // Same size of type. Two sizes on one row are two columns.
                let sameType = abs(before.height - now.height) < smaller * 0.45
                let gap = now.minX - before.maxX
                if sameRow, sameType, gap >= 0, gap < smaller * 0.8 {
                    joined[last] = Line(text: joined[last].text + " " + line.text,
                                        box: joined[last].box.union(line.box))
                    continue
                }
            }
            joined.append(line)
        }
        return joined
    }

    /// Successive lines in the same column belong to one paragraph until a
    /// line ends in sentence punctuation. The engine then sees a whole
    /// sentence, and the answer is laid back over the union of those lines.
    ///
    /// The paragraph is looked for in **its own column**, not merely in the line
    /// just before: a two-column page interleaves the columns line by line, and
    /// a rule that only ever compared with `groups.last` cut the left column's
    /// paragraph into one block per line the moment the right column had a line
    /// in between. Measured 2026-11-13 on the same page: five one-line blocks
    /// where one paragraph was meant, each translated as if it were a sentence
    /// of its own.
    private static func paragraphs(_ lines: [Line], aspect: CGFloat) -> [TextBlock] {
        var groups: [[Line]] = []
        for line in lines {
            if let index = paragraph(in: groups, for: line, aspect: aspect) {
                groups[index].append(line)
                continue
            }
            groups.append([line])
        }
        return groups.map { group in
            let extent = group.dropFirst().reduce(group[0].box) { $0.union($1.box) }
            return TextBlock(text: joined(group.map(\.text)),
                             box: extent, lineCount: group.count)
        }
    }

    /// The open paragraph this line belongs to, if any.
    ///
    /// A few groups back, not all of them: three columns of interleaved text is
    /// the most a page can put between one line of a paragraph and the next, and
    /// an unbounded search would happily reach up a whole screen into an earlier
    /// paragraph that happens to share the same left margin.
    private static func paragraph(in groups: [[Line]], for line: Line,
                                  aspect: CGFloat) -> Int? {
        for index in groups.indices.reversed() where groups.count - index <= 6 {
            guard let previous = groups[index].last else { continue }
            let before = square(previous.box, aspect)
            let now = square(line.box, aspect)
            let smaller = min(before.height, now.height)
            let overlaps = min(before.maxX, now.maxX) > max(before.minX, now.minX)
            // One left margin. A paragraph's lines start at the same place, and
            // the tolerance is under two line heights because a bullet's hanging
            // indent is a new block rather than a continuation.
            let sameColumn = overlaps && abs(before.minX - now.minX) < smaller * 1.5
            // Another column is **skipped**, not decided on: that is what lets a
            // paragraph survive a second column interleaved with it.
            guard sameColumn else { continue }
            // In its own column, the nearest group decides — accepted or not.
            // A search that kept looking after a refusal reached back over a
            // line that was already closed and took the line below it, which
            // built a box that enclosed the closed line: measured 2026-11-13,
            // two blocks whose boxes overlapped, so one answer was drawn on top
            // of the other.
            let gap = before.minY - now.maxY
            // A heading and the line under it sit close together, but they are
            // not one sentence: joining a 30-point title with a 16-point subtitle
            // produced "捕获和翻译它们所处的单词". A quarter, not a third: the
            // 32% between a headline and its body got through at 0.35 on the page
            // measured 2026-11-13, and the merged block drew the headline at the
            // body's size — the words in the right place, the shape of the page
            // gone.
            let similarHeight = abs(before.height - now.height) < smaller * 0.25
            let sequential = gap < smaller * 1.2 && gap > -smaller * 0.5
            return sequential && similarHeight && !endsSentence(previous.text) ? index : nil
        }
        return nil
    }

    /// Soft wraps become spaces; a sentence-ending mark begins a new line.
    /// The set is the one ScreenTextTranslate uses, extended with the CJK and
    /// ellipsis marks a screenshot actually carries.
    private static let terminators: Set<Character> =
        [".", "!", "?", ":", ";", "。", "！", "？", "：", "；", "…"]

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return terminators.contains(last)
    }

    private static func joined(_ lines: [String]) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            out += line
            guard index < lines.count - 1 else { break }
            out += endsSentence(line) ? "\n" : " "
        }
        return out
    }

    /// Harness only: the paragraph join, asked without a picture to read.
    static func joinedForTesting(_ lines: [String]) -> String { joined(lines) }

    /// The picture, shrunk until its longest side fits in `limit`.
    ///
    /// The same ceiling the file path reaches through a thumbnail, for the same
    /// reason: a whole screen on a large display is 6016 points wide, and a read
    /// that takes four seconds behind a question is a question nobody waits for.
    /// A region dragged out of a screen is usually smaller than this and is left
    /// alone — resampling a picture that already fits only costs sharpness.
    private static func fitted(_ image: CGImage, within limit: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > limit, let space = image.colorSpace else { return image }
        let scale = CGFloat(limit) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// The languages asked for, in the order a screenshot is most likely to
    /// be in.
    ///
    /// Checked against what this Mac supports before they are asked for: a
    /// language the current revision does not know fails the whole request
    /// rather than being skipped, and a read that throws is a card that stays
    /// permanently unread. English is the fallback because it is always
    /// supported, and a picture with no words reads the same either way.
    ///
    /// Simplified first, then Traditional, then English: this app's own
    /// language settings are zh-Hans and English, and a screenshot with mixed
    /// Chinese and English is the common case rather than the awkward one.
    private static let languages: [String] = {
        let wanted = ["zh-Hans", "zh-Hant", "en-US"]
        // Asked of a request configured the way the read configures itself.
        // The class method that answers the same question was deprecated in
        // macOS 12, and what it left behind is this: support depends on the
        // level and the revision, so the request that will do the reading is
        // the one that can say what it supports.
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        let available = wanted.filter(supported.contains)
        return available.isEmpty ? ["en-US"] : available
    }()

    /// The text, cut to the ceiling.
    ///
    /// Cut on a character boundary rather than a byte one, and without an
    /// ellipsis: this text exists to be matched against, and a marker appended
    /// to it would be a string nobody typed that the search can now find.
    private static func clip(_ text: String) -> String {
        text.count <= maxCharacters ? text : String(text.prefix(maxCharacters))
    }
}

/// The queues the pictures are read for their words on.
///
/// Two, for the reason `QRScanner` has two: the order work arrives in is not
/// the order it matters in. A card that was just hung should be searchable
/// before a history restored at launch, and the history is two hundred
/// pictures deep — one queue would put a fresh screenshot behind all of it.
///
/// Separate from `QRScanner` rather than sharing its queues. A right click on
/// a fresh screenshot has to find its code menu a second later, and an OCR
/// pass is hundreds of milliseconds against the code reader's hundred: one
/// queue would spend the code reader's latency to save a thumbnail decode. The
/// two read the same picture twice, which costs that decode and buys both of
/// them their own pace.
final class TextScanner {
    static let shared = TextScanner()
    private init() {}

    /// What was just hung. A queue of its own, so it is never behind the
    /// history.
    private let hot = DispatchQueue(label: "app.clothespeg.text.hot", qos: .userInitiated)
    /// The history, filled in after a launch.
    private let cold = DispatchQueue(label: "app.clothespeg.text.cold", qos: .utility)

    /// Reads one picture and reports on the main thread.
    ///
    /// The report runs whether or not anything was found, because an empty
    /// answer is how a card says "this was looked at and it holds no words" —
    /// the fact that keeps it from being read again on every launch.
    func scan(_ url: URL, urgent: Bool, then report: @escaping (String) -> Void) {
        let queue = urgent ? hot : cold
        queue.async {
            let text = PictureText.recognize(in: url)
            DispatchQueue.main.async { report(text) }
        }
    }
}
