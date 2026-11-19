import AppKit
import CoreGraphics

/// A picture with its words replaced, in place, by another language.
///
/// The paper under each line is sampled from the picture itself, so a white
/// panel, a dark menu and a clay button each keep their own colours. Every
/// cover is laid before any word is drawn: a long translation must not be
/// painted over by the cover of the line beside it.
enum TranslatedImage {
    /// The smallest a translation may shrink to, relative to the line it
    /// replaces. Below this the words stop being readable, so an answer that
    /// still does not fit is cut inside its own box rather than shrunk further
    /// or allowed to run past it.
    private static let floorRatio: CGFloat = 0.50
    private static let step: CGFloat = 0.92

    /// How much a line may shrink before the answer is given a second line
    /// instead. Type that is a fifth smaller than the words around it reads as a
    /// different paragraph; two lines at nearly the original size do not.
    private static let singleLineLimit: CGFloat = 0.85

    /// How much taller a block may become, in line heights, when its answer
    /// does not fit the line it replaced.
    ///
    /// Chinese → English runs about twice the width of what it replaces, so a
    /// single line almost never holds the answer at a readable size. Two lines
    /// of extra room is what that actually asks for; the growth only ever
    /// covers pixels that are already the block's own paper colour, so it is
    /// invisible in the result.
    private static let growth: CGFloat = 2.0

    /// `translations` is parallel to `blocks`. A missing answer leaves that
    /// line as it was rather than painting an empty cover over it.
    ///
    /// `trace` exists for the probes: the layout decisions are the part of this
    /// that cannot be seen in a still picture, so the run that measures has to
    /// be able to say what it chose.
    static func render(base: CGImage, blocks: [TextBlock], translations: [String],
                       trace: ((String) -> Void)? = nil) -> CGImage? {
        guard !blocks.isEmpty else { return base }
        let width = base.width, height = base.height
        let size = NSSize(width: width, height: height)
        let rects = blocks.map { rect($0.box, in: size) }
        let sampler = PixelSampler(base)
        let inks = rects.map { sampler.ink(in: $0) }
        // Laid out before anything is painted: the covers have to know how tall
        // each answer grew, and every cover is still laid before any word.
        let plans: [Plan?] = rects.indices.map { index in
            guard index < translations.count, !translations[index].isEmpty else { return nil }
            let lineHeight = rects[index].height / CGFloat(max(1, blocks[index].lineCount))
            let room = sampler.room(around: rects[index],
                                    paper: inks[index].background,
                                    limit: lineHeight * growth,
                                    others: rects.enumerated()
                                        .filter { $0.offset != index }.map(\.element))
            let made = plan(translations[index], in: rects[index],
                            lineCount: blocks[index].lineCount,
                            ink: inks[index].foreground, room: room)
            trace?("block \(index) \(Int(rects[index].width))×\(Int(rects[index].height))"
                + " lines \(blocks[index].lineCount)"
                + " room ↑\(Int(room.up)) ↓\(Int(room.down))"
                + " → \(made.single ? "one line" : "wrapped")"
                + " size \(String(format: "%.1f", made.size))"
                + " box \(Int(made.box.width))×\(Int(made.box.height))")
            return made
        }

        // A CGContext, not an NSImage: `lockFocus` would give this picture the
        // screen's backing scale (2x here), so a 2200x1400 capture would be
        // exported as 4400x2800 — a translated image a size larger than the
        // screenshot it came from.
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // A CGImage lands the right way up in the context's own coordinates;
        // flipping before the draw turns the whole page upside down. Flip only
        // afterwards, for the AppKit drawing that follows in top-left points.
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }

        // Only the words' own box, not a margin around it. An extra margin
        // painted in the sampled colour shows up as a straight edge on
        // anything that is not a flat panel — the clay button was the first
        // report. A block left untranslated gets no cover at all, so the
        // original words stay exactly as they were.
        //
        // The box is the plan's, not the block's: a block that needs a second
        // line has grown into the paper around it, and the cover has to cover
        // the grown box or the new line would land on the old words.
        for (index, plan) in plans.enumerated() {
            guard let plan else { continue }
            inks[index].background.setFill()
            NSBezierPath(roundedRect: plan.box, xRadius: 2, yRadius: 2).fill()
        }
        for (index, plan) in plans.enumerated() {
            guard let plan else { continue }
            draw(translations[index], plan: plan)
        }
        return context.makeImage()
    }

    /// Where one block's answer goes: the box it may paint, the size it is
    /// painted at, and whether it stayed on one line.
    private struct Plan {
        var box: NSRect
        var size: CGFloat
        var single: Bool
        var attributes: [NSAttributedString.Key: Any]
        /// The height the drawing actually wants, which is not the height
        /// `boundingRect` reports — see `needed(_:in:attributes:size:)`.
        var needed: CGFloat
    }

    /// The height the layout will really take.
    ///
    /// `boundingRect` leaves out the leading of the last line: measured
    /// 2026-11-13 on a 20.8 pt face, three lines come back as 72 and need 75 to
    /// draw. Handing the box the reported height would crop the last line, so
    /// the answer would lose its ending to a rounding — the same complaint the
    /// fit test was already being fixed for. A fifth of the type size is the
    /// gap that covers it.
    private static func needed(_ words: String, in rect: NSRect,
                               attributes: [NSAttributedString.Key: Any],
                               size: CGFloat) -> CGFloat {
        measure(words, in: rect, attributes: attributes).height + size * 0.2
    }

    /// The layout for one block.
    ///
    /// One line first, at the largest size that still fits the width the
    /// picture gave it. If the answer cannot be read on one line at any
    /// acceptable size, the block takes a second line — out of the paper
    /// around it, never out of its neighbours — and the answer wraps into
    /// whatever the grown box holds.
    ///
    /// The width test for a single line is the whole of a bug reported on
    /// 2026-11-13: 「原位置翻译，有时候会显示不全」. Measured with
    /// `.usesLineFragmentOrigin`, a string is laid out *inside* the width it is
    /// handed, so its reported width never exceeds that width — the test was
    /// true for a line twice as long as its box, the shrink loop never ran, and
    /// `draw(at:)` (which does not wrap) painted the answer straight across the
    /// bubble and off the edge of the picture. Hence `unwrapped(_:)` below.
    private static func plan(_ words: String, in rect: NSRect, lineCount: Int,
                             ink: NSColor,
                             room: (up: CGFloat, down: CGFloat)) -> Plan {
        let lineHeight = rect.height / CGFloat(max(1, lineCount))
        let largest = max(9, lineHeight * 0.8)
        let floor = max(7, lineHeight * floorRatio)

        if lineCount == 1 {
            // A little smaller is fine; much smaller is not — below this the
            // answer takes a second line, where it can stay near the original
            // size.
            let smallest = max(floor, largest * singleLineLimit)
            var size = largest
            var attributes = Self.attributes(size: size, colour: ink)
            while size > smallest {
                if unwrapped(words, attributes).width <= rect.width - 4 { break }
                size *= step
                attributes = Self.attributes(size: size, colour: ink)
            }
            if unwrapped(words, attributes).width <= rect.width - 4 {
                return Plan(box: rect, size: size, single: true, attributes: attributes,
                            needed: unwrapped(words, attributes).height)
            }
        }

        // It has to wrap. Take the room the block's own paper offers, capped so
        // a white page does not turn one line into a paragraph.
        let widest = max(9, lineHeight * 0.8)
        let ceiling = rect.height + max(0, min(room.up + room.down, lineHeight * growth))
        var size = widest
        var attributes = Self.attributes(size: size, colour: ink)
        var height = needed(words, in: rect, attributes: attributes, size: size)
        // The cover is exactly as tall as the answer needs — the test and the
        // drawing use the same box, so a line the fit allowed can never be cut
        // by the draw. Only when even the floor size overflows the room the
        // paper offers does the answer get an ellipsis.
        while size > floor, height > ceiling {
            size *= step
            attributes = Self.attributes(size: size, colour: ink)
            height = needed(words, in: rect, attributes: attributes, size: size)
        }
        let boxHeight = min(max(rect.height, height), ceiling)
        // Down first: words sit where the old ones sat, so the block grows away
        // from the line above it rather than into it.
        var spare = max(0, boxHeight - rect.height)
        let down = min(room.down, spare)
        spare -= down
        let up = min(room.up, spare)
        let box = NSRect(x: rect.minX, y: rect.minY - up, width: rect.width,
                         height: rect.height + down + up)
        return Plan(box: box, size: size, single: false, attributes: attributes,
                    needed: height)
    }

    private static func draw(_ words: String, plan: Plan) {
        if plan.single {
            let measured = unwrapped(words, plan.attributes)
            (words as NSString).draw(
                at: NSPoint(x: plan.box.minX + 2, y: plan.box.midY - measured.height / 2),
                withAttributes: plan.attributes)
            return
        }
        // Wrapped, and cut with an ellipsis if even the grown box is short.
        // Contained by construction: whatever the answer's length, it stays in
        // the box the picture gave this block. `truncatesLastVisibleLine` is
        // what keeps this a *wrapped* paragraph with an ellipsis on its last
        // line — the paragraph style alone drops the text onto one line and
        // cuts the rest, which is a screenshot that looks like it is missing
        // half a sentence.
        let height = min(plan.needed, plan.box.height)
        let box = NSRect(x: plan.box.minX + 2,
                         y: plan.box.minY + max(0, (plan.box.height - height) / 2),
                         width: plan.box.width - 4,
                         height: height + 1)
        (words as NSString).draw(with: box,
                                 options: [.usesLineFragmentOrigin,
                                           .truncatesLastVisibleLine],
                                 attributes: plan.attributes)
    }

    private static func measure(_ words: String, in rect: NSRect,
                                attributes: [NSAttributedString.Key: Any]) -> NSSize {
        (words as NSString).boundingRect(
            with: NSSize(width: rect.width - 4, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes).size
    }

    /// The width of the answer laid out as one line — that is, the width it
    /// asks for, not the width it can be squeezed into.
    private static func unwrapped(_ words: String,
                                  _ attributes: [NSAttributedString.Key: Any]) -> NSSize {
        (words as NSString).size(withAttributes: attributes)
    }

    private static func attributes(size: CGFloat,
                                   colour: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Word wrapping, and *not* `.byTruncatingTail`: that mode collapses the
        // draw onto a single line and cuts the rest of the sentence, which is
        // exactly the "half the answer is missing" the ellipsis was meant to
        // report. The cut is done by `truncatesLastVisibleLine` at the drawing
        // call instead, which truncates the last line it can fit.
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: colour,
                .paragraphStyle: paragraph]
    }

    /// Vision's box is normalised and bottom-left; NSImage draws top-left.
    private static func rect(_ box: CGRect, in size: NSSize) -> NSRect {
        NSRect(x: box.minX * size.width,
               y: (1 - box.maxY) * size.height,
               width: (box.maxX - box.minX) * size.width,
               height: (box.maxY - box.minY) * size.height)
    }
}

/// Reads the pixels under a text block. The median colour is the paper; the
/// average of the pixels furthest from it is the ink.
private struct PixelSampler {
    let width: Int, height: Int, bytesPerRow: Int
    let data: UnsafePointer<UInt8>
    /// The context owns the buffer `data` points into.
    private let holder: CGContext

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A CGImage is top-down, a CGContext bottom-up. Without this flip the
        // sampler reads a mirrored part of the picture: a clay button comes
        // back as white paper and the words on it vanish.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytesPerRow = context.bytesPerRow
        data = UnsafePointer(context.data!.assumingMemoryBound(to: UInt8.self))
        holder = context
    }

    struct Ink {
        let background: NSColor
        let foreground: NSColor
    }

    func ink(in rect: NSRect) -> Ink {
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
        var samples: [(Double, Double, Double)] = []
        var y = y0
        while y < y1 {
            let row = height - 1 - y
            var x = x0
            while x < x1 {
                let p = data + row * bytesPerRow + x * 4
                samples.append((Double(p[0]), Double(p[1]), Double(p[2])))
                x += 2
            }
            y += 2
        }
        guard !samples.isEmpty else {
            return Ink(background: .white, foreground: .black)
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func middle(_ pool: [(Double, Double, Double)]) -> (Double, Double, Double) {
            (median(pool.map { $0.0 }), median(pool.map { $0.1 }), median(pool.map { $0.2 }))
        }
        func distance(_ a: (Double, Double, Double),
                      _ b: (Double, Double, Double)) -> Double {
            (a.0 - b.0) * (a.0 - b.0)
                + (a.1 - b.1) * (a.1 - b.1)
                + (a.2 - b.2) * (a.2 - b.2)
        }
        // The paper is the colour the box is mostly painted in, and a single
        // median does not find it: a line of type fills a tight box, so the
        // median lands between paper and ink. Measured on 2026-11-13 — a dark
        // chat bubble came back 58 where it is 44, and the cover showed as a
        // lighter band across the block with no words on it. Keep only the
        // pixels near the current guess and take the median again; three rounds
        // settle on the flat colour the box actually sits on.
        var paper = middle(samples)
        for _ in 0..<3 {
            let near = samples.filter { distance($0, paper) < 400 }
            guard near.count * 3 >= samples.count else { break }
            let next = middle(near)
            if next == paper { break }
            paper = next
        }
        // The furthest tenth only. Averaging every non-background pixel drags
        // antialiasing into the ink and turns black type pale grey.
        let ranked = samples.map { (distance($0, paper), $0) }.sorted { $0.0 > $1.0 }
        let inkPixels = ranked.prefix(max(1, ranked.count / 10)).map { $0.1 }
        let total = inkPixels.reduce((0.0, 0.0, 0.0)) {
            ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2)
        }
        let count = Double(inkPixels.count)
        let channel: (Double) -> CGFloat = {
            CGFloat(max(0, min(255, $0 / count)) / 255)
        }
        // Device RGB, both of them. The samples are the context's own bytes, and
        // a `calibratedRed` colour is generic RGB: painting one into a device
        // context converts it and lifts the value — measured 2026-11-13, a
        // bubble that is 44 came back as a 58 band across the block, which reads
        // as "the cover does not match the picture". Same bytes in, same bytes
        // out.
        return Ink(
            background: NSColor(deviceRed: CGFloat(paper.0 / 255),
                                green: CGFloat(paper.1 / 255),
                                blue: CGFloat(paper.2 / 255), alpha: 1),
            foreground: NSColor(deviceRed: channel(total.0),
                                green: channel(total.1),
                                blue: channel(total.2), alpha: 1))
    }

    /// How far the paper around a block stays the same flat colour: the room an
    /// answer that outgrew its line may take.
    ///
    /// A block's box is the words' ink box, not the panel they sit on, so a line
    /// of Chinese in a chat bubble has thirty-odd points of the same colour under
    /// it. Growing into exactly that, and not one pixel further, is what lets a
    /// translation wrap instead of being cut — and the growth is invisible,
    /// because it is painted in the colour that was already there.
    func room(around rect: NSRect, paper: NSColor, limit: CGFloat,
              others: [NSRect]) -> (up: CGFloat, down: CGFloat) {
        guard limit > 0, let colour = paper.usingColorSpace(.deviceRGB) else { return (0, 0) }
        let target = (Double(colour.redComponent * 255),
                      Double(colour.greenComponent * 255),
                      Double(colour.blueComponent * 255))
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
        guard x1 > x0 else { return (0, 0) }
        let avoid = others.map { $0.insetBy(dx: -1, dy: -1) }
        // A row is usable when it is clear of every other block and painted in
        // this block's own paper. Anything else — another line, a border, the
        // edge of the panel — stops the growth there.
        func usable(_ y: CGFloat) -> Bool {
            guard y >= 0, y + 1 <= CGFloat(height) else { return false }
            for other in avoid where other.minY < y + 1 && y < other.maxY { return false }
            return flat(row: Int(y), from: x0, to: x1, near: target)
        }
        var up: CGFloat = 0
        while up + 1 <= limit, usable(rect.minY - up - 1) { up += 1 }
        var down: CGFloat = 0
        while down + 1 <= limit, usable(rect.maxY + down) { down += 1 }
        return (up, down)
    }

    /// Whether a row is painted in one colour. A couple of stray pixels are
    /// allowed — an antialiased edge is not a word.
    private func flat(row y: Int, from x0: Int, to x1: Int,
                      near paper: (Double, Double, Double)) -> Bool {
        let row = height - 1 - y
        var off = 0, seen = 0
        var x = x0
        while x < x1 {
            let p = data + row * bytesPerRow + x * 4
            let dr = Double(p[0]) - paper.0
            let dg = Double(p[1]) - paper.1
            let db = Double(p[2]) - paper.2
            if dr * dr + dg * dg + db * db > 144 { off += 1 }   // ~7 a channel
            seen += 1
            x += 2
        }
        return seen > 0 && off * 50 <= seen
    }
}

#if DEBUG
/// Where the boxes came from: Vision's own observations, before grouping.
///
/// Offline by design — no engine, no session — because the question it answers
/// ("which boxes did we glue together, and did that cross a column?") has to be
/// askable without paying for a translation first.
enum TextProbe {
    static func run(image source: String) -> String {
        guard let image = NSImage(contentsOfFile: source),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return "no image at \(source)" }
        var out = ["raw lines from \(cg.width)x\(cg.height):"]
        for line in PictureText.rawLines(in: cg) {
            let at = String(format: "%.3f,%.3f %.3f×%.3f", line.box.minX, line.box.minY,
                            line.box.width, line.box.height)
            out.append("\(at) «\(line.text.prefix(60))»")
        }
        out.append("grouped:")
        for (index, block) in PictureText.recognizeBlocks(in: cg).enumerated() {
            let at = String(format: "%.3f,%.3f %.3f×%.3f", block.box.minX, block.box.minY,
                            block.box.width, block.box.height)
            out.append("\(index) \(at) lines \(block.lineCount) «\(block.text.prefix(60))»")
        }
        return out.joined(separator: "\n")
    }
}
#endif

// MARK: - Probe

/// The whole in-place pipeline in the signed app binary, not in a standalone
/// script: blocks, one batch translation, and the repaint. The SwiftUI session
/// arrives on the run loop, so the same pump the translation probe uses is the
/// only way to wait for it without blocking the actor that has to answer.
@available(macOS 15.0, *)
enum InPlaceProbe {
    @MainActor
    static func run(image source: String, picture output: String) -> String {
        let box = Box()
        Task { @MainActor in
            guard let image = NSImage(contentsOfFile: source),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                box.lines.append("no image at \(source)")
                box.done = true
                return
            }
            let blocks = PictureText.recognizeBlocks(in: cg)
            box.lines.append("blocks \(blocks.count) from \(cg.width)x\(cg.height)")
            do {
                let began = Date()
                // The same choice the app makes, so the probe measures the engine
                // that will actually answer: a probe that always used the
                // system's translator would have shown a clean run on the night
                // the remote one was leaving lines untranslated.
                let target = Locale.Language(identifier: TranslationTargets.current)
                box.lines.append("into \(TranslationTargets.current) — \(TranslationAPI.name(of: target))")
                let words: [String]
                if let handed = ProcessInfo.processInfo.environment["CLOTHESPEG_INPLACE_ANSWER"] {
                    // A fixed answer for laying out: a 7B model at 0.2 sometimes
                    // echoes the source or answers in the wrong script, and a
                    // measurement of the *layout* must not depend on that.
                    words = blocks.indices.map { _ in handed }
                } else if TranslationAPI.isConfigured {
                    words = try await TranslationAPI.translateLines(blocks.map(\.text),
                                                                     into: target)
                } else {
                    words = try await Translator.shared.translateBlocks(
                        blocks.map(\.text),
                        from: Locale.Language(identifier: "en"),
                        to: target)
                }
                box.lines.append("engine "
                    + (TranslationAPI.isConfigured ? TranslationAPI.model : "system"))
                box.lines.append("batch \(words.count) in "
                    + "\(Int(Date().timeIntervalSince(began) * 1000)) ms")
                let blank = words.filter(\.isEmpty).count
                box.lines.append("answered \(words.count - blank)/\(words.count)"
                    + (blank > 0 ? " — \(blank) left in the original" : ""))
                // The pair, not just the count. A run can answer every line and
                // still paint it in the wrong place — the only way to see that
                // from a trace is to read back which original each answer was
                // paired with, against the box it landed in.
                for (index, block) in blocks.enumerated() {
                    let answer = index < words.count ? words[index] : ""
                    let at = String(format: "%.2f,%.2f %.3f×%.3f", block.box.minX,
                                    block.box.minY, block.box.width, block.box.height)
                    box.lines.append("pair \(index) box \(at)"
                        + " «\(block.text.prefix(38))» → «\(answer.prefix(38))»")
                }
                guard let rendered = TranslatedImage.render(base: cg, blocks: blocks,
                                                            translations: words,
                                                            trace: { box.lines.append($0) })
                else {
                    box.lines.append("render failed")
                    box.done = true
                    return
                }
                box.lines.append("render \(rendered.width)x\(rendered.height)")
                let picture = NSImage(cgImage: rendered,
                                      size: NSSize(width: rendered.width,
                                                   height: rendered.height))
                if let tiff = picture.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: output))
                    box.lines.append("wrote \(output)")
                }
                box.lines.append("first: \(words.first ?? "")")
            } catch {
                box.lines.append("failed: \(error.localizedDescription)")
            }
            box.done = true
        }
        TranslateProbe.pump(seconds: 30) { box.done }
        if !box.done { box.lines.append("no answer in 30 s") }
        return "in-place probe:\n" + box.lines.joined(separator: "\n")
    }

    private final class Box: @unchecked Sendable {
        var lines: [String] = []
        var done = false
    }
}
