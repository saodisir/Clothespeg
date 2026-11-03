import Foundation
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
