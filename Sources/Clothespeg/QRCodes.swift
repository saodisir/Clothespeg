import Foundation
import ImageIO
import Vision

/// Reading a QR code out of a picture.
///
/// Vision rather than a third-party decoder: it ships with macOS, it needs no
/// network, and it costs nothing to link. The one thing it will not tolerate
/// is a large picture handed to it whole — a 7680×4320 screen grab takes
/// nearly three seconds that way — so everything here goes through a
/// thumbnail first.
///
/// 1600 points on the long side, which is a number this was measured to
/// rather than guessed at. A code occupying 4% of the width of a 4K grab
/// survives it, and the same code at 800 is not found at all. Past 1600 the
/// read only gets slower and finds nothing more.
enum QRCodes {
    /// The longest side of the picture that is handed to Vision.
    static let maxPixel = 1600

    /// Every QR code in a picture, in the order Vision found them, or an
    /// empty array when there is none.
    ///
    /// Blocking, on purpose — the caller puts it on a queue. Reading a
    /// screenshot is about a hundred milliseconds, which is nothing in the
    /// background and a visible stutter on the line.
    static func detect(in url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        // Through the thumbnail rather than the decoded image, which is the
        // same call the card's own thumbnail is made with: the whole picture
        // is never held in memory, whatever its size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return []
        }
        let request = VNDetectBarcodesRequest()
        // QR only, deliberately. A one-dimensional barcode is not a QR code:
        // its content is a row of digits with nowhere to go, and Code128 in
        // particular reads false positives out of any striped picture — a
        // right-click item headed "QR code" over a screenshot of a table is
        // worse than there being no item at all.
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            log.error("QR read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// The address this content points at, when it points at one.
    ///
    /// The same whitelist a link card uses, and for the same reason: opening
    /// whatever scheme a picture happens to name is how a QR code becomes a
    /// way to run something on somebody else's machine. A code from a
    /// stranger is the last thing in this app that should be allowed to pick
    /// its own handler.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), trimmed.count <= 2048,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "mailto", "file"].contains(scheme) else { return nil }
        return url
    }
}

/// The queues the pictures are read on.
///
/// Two rather than one, because the order the work arrives in is not the order
/// it matters in. A code that was just copied has to be read now — its menu
/// items are supposed to be there on the next right click, a second later —
/// while two hundred pictures restored from the history can wait as long as
/// they like. One queue cannot do both: a cold card already in it would hold
/// up a hot one by a hundred milliseconds each, which on the first launch
/// after this ships is twenty seconds deep.
final class QRScanner {
    static let shared = QRScanner()
    private init() {}

    /// What was just hung. A queue of its own, so it is never behind the
    /// history.
    private let hot = DispatchQueue(label: "app.clothespeg.qr.hot", qos: .userInitiated)
    /// The history, filled in after a launch.
    private let cold = DispatchQueue(label: "app.clothespeg.qr.cold", qos: .utility)

    /// Reads one picture and reports on the main thread.
    ///
    /// The report runs whether or not anything was found, because an empty
    /// answer is how a card says "this was looked at and it holds no code" —
    /// the fact that keeps it from being read again on every launch.
    func scan(_ url: URL, urgent: Bool, then report: @escaping ([String]) -> Void) {
        let queue = urgent ? hot : cold
        queue.async {
            let texts = QRCodes.detect(in: url)
            DispatchQueue.main.async { report(texts) }
        }
    }
}
