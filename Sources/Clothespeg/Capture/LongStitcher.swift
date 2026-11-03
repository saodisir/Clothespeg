import CoreGraphics
import Vision

/// Stitching a region that keeps growing downwards into one tall picture.
///
/// The frames arrive by hand: the person scrolls, this samples, and nothing is
/// posted into the other app — no `CGEvent`, no Accessibility permission. So
/// the only thing known about two consecutive frames is that the content moved;
/// *how far* has to be measured, and measuring it is the whole job.
///
/// Measured with Vision's translational registration over the whole frame, then
/// checked against the pixels it claims to explain. The bands are gone on
/// purpose: five horizontal bands, each registered against the band in the same
/// place in the other frame, sounds robust and is arithmetic nonsense — when the
/// content moves further than one band is tall, band *i* of the new frame shows
/// content that was never in band *i* of the old one, and registration answers
/// with confident noise. Measured on synthetic frames with a 300-pixel scroll
/// over a 400-pixel frame, the five bands answered 45, 13, -21, 45 and -25,
/// none of which is 300 and any of which would have been stitched.
///
/// The real defence against a wrong answer is not more answers, it is looking at
/// what the answer implies: the overlap it predicts has to actually look the
/// same. That check is below, and it is what turns a plausible number into a
/// refusal.
///
/// Pixels throughout. The frames all come from the same rectangle on the same
/// display, so they are all the same size and the scale never has to be known
/// here — it is only needed to say the height in points, which is the caller's
/// business.
final class LongStitcher {
    enum Step {
        case advanced(pixels: Int)
        /// Nothing moved: the wheel is at rest, or the page has reached its end.
        case still
        /// The content moved the other way. This mode only grows downwards.
        case backwards
        /// No usable measurement: too fast to still overlap, or nothing in the
        /// frame worth recognising.
        case lost(String)
    }

    /// The pixel size of one frame. Every frame after the first must match it.
    private(set) var size = CGSize.zero
    private var frames: [CGImage] = []
    /// Where each frame's top edge sits, measured downwards from the top of the
    /// stitched picture.
    private var tops: [Int] = []

    /// A ceiling, because this is a picture that grows while the person keeps
    /// scrolling and a 90,000-pixel-tall canvas is a memory problem, not a
    /// screenshot. Roughly twenty screens.
    private static let maxHeight = 20000

    var count: Int { frames.count }
    var height: Int { frames.first.map { $0.height + (tops.last ?? 0) } ?? 0 }

    /// The first frame: it is the top of the picture, and it is also the
    /// reference every later frame is measured against.
    func start(_ frame: CGImage) {
        frames = [frame]
        tops = [0]
        size = CGSize(width: frame.width, height: frame.height)
    }

    /// What it says when it cannot go on, named once each.
    ///
    /// Properties rather than literals at the point of use, because the bar
    /// measures them to pin its own width: a note that appears half-way through
    /// a long capture must not make the capsule grow, and a bar that grows moves
    /// the Done pill out from under the hand that was reaching for it.
    static var noteResized: String { L("The area changed size while it was being captured.") }
    static var noteTooFast: String { L("That scroll was too fast to follow — go a little slower.") }
    static var noteCeiling: String { L("That is as long as one picture can be.") }
    static var notes: [String] { [noteResized, noteTooFast, noteCeiling] }

    /// One more frame, taken after the person scrolled.
    func append(_ frame: CGImage) -> Step {
        guard let last = frames.last else {
            start(frame)
            return .advanced(pixels: 0)
        }
        guard frame.width == Int(size.width), frame.height == Int(size.height) else {
            return .lost(Self.noteResized)
        }
        guard let moved = Self.advance(from: last, to: frame) else {
            return .lost(Self.noteTooFast)
        }
        if moved == 0 { return .still }
        if moved < 0 { return .backwards }
        // Less than a sixth of the frame left in common is not an overlap, it is
        // a guess. Better to stop and say so than to stitch a seam nobody can
        // find until the picture is published.
        let overlap = Int(size.height) - moved
        guard overlap >= Int(size.height) / 6 else {
            return .lost(Self.noteTooFast)
        }
        guard height + moved <= Self.maxHeight else {
            return .lost(Self.noteCeiling)
        }
        frames.append(frame)
        tops.append((tops.last ?? 0) + moved)
        return .advanced(pixels: moved)
    }

    /// The stitched picture.
    ///
    /// One canvas, drawn into at the end rather than grown frame by frame: the
    /// height is not known until the last frame arrives, and re-allocating a
    /// canvas thirty times to avoid one pass over the pixels is a trade that
    /// loses.
    ///
    /// y-up, like every Core Graphics context: the *top* of the picture is the
    /// highest y, so a frame whose top edge is `tops[i]` below the top of the
    /// picture is drawn with its top at `height - tops[i]`.
    func image() -> CGImage? {
        guard let first = frames.first else { return nil }
        let width = first.width
        let tall = height
        guard tall >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: tall,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for (index, frame) in frames.enumerated() {
            let top = tops[index]
            let rect = CGRect(x: 0, y: CGFloat(tall - top - frame.height),
                              width: CGFloat(frame.width), height: CGFloat(frame.height))
            context.draw(frame, in: rect)
        }
        return context.makeImage()
    }

    // MARK: Measuring

    /// How different the overlap is allowed to look and still be believed.
    ///
    /// Measured rather than guessed: on synthetic frames the same content
    /// scores 0.0000, and a registration that has locked onto the wrong place
    /// scores 0.08–0.09. Anything in between is a judgement call, and 0.03 is
    /// four times the noise of identical frames and a third of a wrong match.
    private static let likeness: Double = 0.03

    /// How far the content moved between two frames, in pixels, positive
    /// downwards. Nil when the answer does not survive being checked.
    ///
    /// The sign is not a guess either. Vision answers with the transform that
    /// aligns the *targeted* image to the handler's, in a y-up space, so a
    /// frame taken after scrolling down reports `ty = -300` for a 300-pixel
    /// scroll — measured on synthetic frames at 37, 100, 250 and 300 pixels
    /// before this line was written.
    nonisolated static func advance(from previous: CGImage, to next: CGImage) -> Int? {
        let width = min(previous.width, next.width)
        let height = min(previous.height, next.height)
        guard width >= 16, height >= 24,
              let was = previous.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)),
              let now = next.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))
        else { return nil }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: now)
        do {
            try VNImageRequestHandler(cgImage: was).perform([request])
        } catch {
            return nil
        }
        guard let found = request.results?.first as? VNImageTranslationAlignmentObservation
        else { return nil }
        let moved = -Int(found.alignmentTransform.ty.rounded())
        guard moved != 0 else { return 0 }
        // Both directions are verified the same way, and that is the point: a
        // 380-pixel scroll over a 400-pixel frame came back as -295 — a wrong
        // match with a plausible sign, which would have been reported to the
        // person as "you scrolled the wrong way" instead of being refused.
        let distance = abs(moved)
        guard distance < height else { return nil }
        let overlap = height - distance
        guard overlap >= height / 6 else { return nil }
        // Scrolling down: the foot of the old frame reappears at the top of the
        // new one. Scrolling up: the other way round. Either way the strips that
        // ought to be identical have to look identical.
        let left = previous.cropping(to: CGRect(x: 0, y: moved > 0 ? distance : 0,
                                                width: width, height: overlap))
        let right = next.cropping(to: CGRect(x: 0, y: moved > 0 ? 0 : distance,
                                             width: width, height: overlap))
        guard let left, let right, let difference = meanDifference(left, right),
              difference <= likeness else { return nil }
        return moved
    }

    /// How far apart two pictures are, as a fraction of full scale, compared as
    /// 16 × 16 thumbnails.
    ///
    /// Small enough to be cheap per frame, large enough that subpixel
    /// antialiasing during a scroll averages out instead of reading as a
    /// difference.
    nonisolated static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard let left = signature(a), let right = signature(b), left.count == right.count
        else { return nil }
        var total = 0.0
        for index in 0..<left.count {
            total += abs(Double(left[index]) - Double(right[index]))
        }
        return total / Double(left.count) / 255.0
    }

    private nonisolated static func signature(_ image: CGImage, side: Int = 16) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress,
                                          width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }
}
