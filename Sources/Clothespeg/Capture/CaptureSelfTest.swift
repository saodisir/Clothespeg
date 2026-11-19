import AppKit
import Carbon

/// What the capture says about itself when nobody is going to click anything.
///
/// Every line here is a claim that could be false, and the point of running it
/// is to find out which. The two that matter most are the pair at the end: the
/// same rectangle is taken twice — once cut out of the backdrop, once grabbed
/// from the screen — and the two pictures are compared. If the crop's
/// arithmetic is wrong the sizes still match and only the picture is of the
/// wrong place, which is precisely the failure that looks like nothing at all
/// until somebody notices a screenshot of the wrong corner.
///
/// Run with `CLOTHESPEG_CAPTURE_SELFTEST=/tmp/capture.txt`, which writes the
/// lines there and quits. Nothing in ordinary use sets it.
enum CaptureSelfTest {
    static func run() -> String {
        var lines: [String] = []
        lines.append("capture permission: \(ScreenGrab.hasAccess ? "granted" : "NOT GRANTED")")

        let pickable = WindowPick.windows()
        let front = pickable.first.map {
            "\($0.owner.isEmpty ? "?" : $0.owner) \(Int($0.frame.width))×\(Int($0.frame.height)) at \(Int($0.frame.minX)),\(Int($0.frame.minY))"
        } ?? "none"
        lines.append("capture windows: \(pickable.count) pickable, front \(front), "
                     + "\(pickable.filter(\.isOwn).count) of this app")
        lines.append(ownLine())

        lines.append(ratioLine())
        lines.append(frameLine())
        lines.append(longLine())
        lines.append(MainActor.assumeIsolated { doneLine() })
        lines.append(MainActor.assumeIsolated { textLine() })
        lines.append(countLine())
        lines.append(languageLine())
        lines.append(MainActor.assumeIsolated { againLine() })
        lines.append(MainActor.assumeIsolated { chooseLine() })
        lines.append(MainActor.assumeIsolated { chipsLine() })
        lines.append(inPlaceFitLine())
        lines.append(MainActor.assumeIsolated { languagesLine() })
        lines.append(MainActor.assumeIsolated { styleLine() })
        lines.append(MainActor.assumeIsolated { cardLine() })
        lines.append(MainActor.assumeIsolated { revealLine() })
        lines.append(MainActor.assumeIsolated { colourLine() })
        lines.append(keysLine())
        lines.append(translationAPILine())
        if #available(macOS 15.0, *) {
            lines.append(MainActor.assumeIsolated { TranslateProbe.line() })
        }

        guard ScreenGrab.hasAccess else {
            lines.append("capture grab: skipped, no permission")
            lines.append("capture compare: skipped, no permission")
            return lines.joined(separator: "\n")
        }
        guard let screen = NSScreen.main else {
            lines.append("capture grab: no screen")
            lines.append("capture compare: no screen")
            return lines.joined(separator: "\n")
        }

        // A fixed probe rather than a random one, so two runs are comparable:
        // a band near the bottom left of the screen, which crosses the corner
        // that a flipped y would get most wrong.
        let probe = CGRect(x: screen.frame.minX + 40,
                           y: screen.frame.minY + 40,
                           width: 320,
                           height: 180)

        let box = Box()
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            do {
                let whole = try await ScreenGrab.screenImage(of: screen)
                let expected = "\(Int((screen.frame.width * screen.backingScaleFactor).rounded()))×\(Int((screen.frame.height * screen.backingScaleFactor).rounded()))"
                box.grab = "capture grab: \(whole.width)×\(whole.height), screen "
                    + "\(Int(screen.frame.width))×\(Int(screen.frame.height)) "
                    + "@\(screen.backingScaleFactor)x, expected \(expected)"

                guard let cut = CaptureController.crop(whole, to: probe, on: screen) else {
                    box.compare = "capture compare: FAILED, the crop came back empty"
                    group.leave()
                    return
                }
                // The same rectangle the other way: asked of the window server
                // directly. Not the same instant, so a playing video will
                // differ — but a wrong crop differs by the whole picture.
                let direct = try await ScreenGrab.areaImage(in: probe, on: screen)
                let difference = meanDifference(cut, direct)
                let sizes = "crop \(cut.width)×\(cut.height), grabbed \(direct.width)×\(direct.height)"
                if let difference {
                    let verdict = difference < 0.06 ? "same place" : "DIFFERENT PLACES"
                    box.compare = String(format: "capture compare: %@, mean difference %.4f", sizes, difference)
                        + " — \(verdict)"
                } else {
                    box.compare = "capture compare: \(sizes), sizes disagree — the crop is not the rectangle asked for"
                }
            } catch {
                box.grab = "capture grab: failed \(error.localizedDescription)"
                box.compare = "capture compare: skipped"
            }
            group.leave()
        }
        _ = group.wait(timeout: .now() + 20)
        lines.append(box.grab)
        lines.append(box.compare)
        return lines.joined(separator: "\n")
    }

    /// Whether a window of this app can be pointed at, stated as the rule rather
    /// than as a window.
    ///
    /// The four layers asked about are the ones this app really puts up — the
    /// editor, the clipboard line, a note or the search, a pinned picture — plus
    /// the capture's own overlay, which must never become one of the choices.
    /// A live version of this would need a real window, a moment for the window
    /// server to list it, and a picture to look at; the mistake it guards is one
    /// line of arithmetic, so that is where the check goes.
    private static func ownLine() -> String {
        let editor = WindowPick.admits(layer: 0, isOwn: true, alpha: 1)
        let line = WindowPick.admits(layer: Int(CGWindowLevelForKey(.floatingWindow)),
                                     isOwn: true, alpha: 1)
        let note = WindowPick.admits(layer: Int(CGWindowLevelForKey(.statusWindow)),
                                     isOwn: true, alpha: 1)
        let pin = WindowPick.admits(layer: WindowPick.ceiling, isOwn: true, alpha: 1)
        let overlay = WindowPick.admits(layer: WindowPick.ceiling + 1, isOwn: true, alpha: 1)
        let foreign = WindowPick.admits(layer: Int(CGWindowLevelForKey(.floatingWindow)),
                                        isOwn: false, alpha: 1)
        let invisible = WindowPick.admits(layer: 0, isOwn: true, alpha: 0)
        let ok = editor && line && note && pin && !overlay && !foreign && !invisible
        return "capture own: editor/line/note/pin pickable, overlay not, "
            + "another app's panel not, transparent not " + (ok ? "ok" : "WRONG")
    }

    /// The ratio lock, checked as arithmetic rather than by eye.
    ///
    /// Four drags against a made-up 1000 × 800 screen: free, the two shapes
    /// someone actually asks for (16:9 and 9:16 — one is driven by the width,
    /// the other by the height, and an implementation that only ever drives the
    /// width passes the first and fails the second), and one that runs out of
    /// screen, where the clamp has to shrink both sides together or quietly
    /// break the lock. Each case prints its own verdict, because a number that
    /// merely looks plausible is not a check.
    private static func ratioLine() -> String {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        func check(_ aspect: CropAspect, _ to: CGPoint, from start: CGPoint = .zero) -> String {
            let rect = CaptureSurface.rectangle(from: start, to: to, aspect: aspect, within: bounds)
            guard let ratio = aspect.ratio else {
                let raw = "\(Int(rect.width))×\(Int(rect.height))"
                return raw == "400×300" ? "free \(raw) ok" : "free \(raw) WRONG (expected 400×300)"
            }
            let got = Double(rect.width / max(rect.height, 1))
            let shaped = abs(got - Double(ratio)) / Double(ratio) < 0.01
            let inside = rect.width > 0 && bounds.contains(rect)
            let verdict = shaped && inside ? "ok" : (shaped ? "OUT OF BOUNDS" : "WRONG SHAPE")
            return "\(aspect.title) \(Int(rect.width))×\(Int(rect.height)) \(verdict)"
        }
        let cases = [
            check(.free, CGPoint(x: 400, y: 300)),
            check(.sixteenNine, CGPoint(x: 400, y: 300)),
            check(.nineSixteen, CGPoint(x: 300, y: 700)),
            // Anchored at the bottom-right of the made-up screen and dragged
            // past its top-right corner: the height has to give.
            check(.square, CGPoint(x: 900, y: 780), from: CGPoint(x: 60, y: 40)),
        ]
        return "capture ratios: " + cases.joined(separator: ", ")
    }

    /// Adjusting a frame that has already been drawn, checked the same way.
    ///
    /// Six claims, one per way the frame can be changed, against the same
    /// made-up 1000 × 800 screen. Each prints the sizes it got, so a wrong
    /// answer is visible as a wrong number rather than as a diff nobody reads:
    /// a corner that forgets the lock, a side that breaks it, a frame that
    /// runs out of screen, a free side that moves the far edge by mistake, a
    /// side dragged past its own opposite (which must stop at a grabbable
    /// width, not invert), and a frame dragged off the edge of the screen.
    private static func frameLine() -> String {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        /// A 16:9 frame in the middle, the shape most of these start from.
        let wide = CGRect(x: 100, y: 100, width: 400, height: 225)

        func check(_ name: String, _ got: CGRect, _ want: CGRect) -> String {
            let close = abs(got.minX - want.minX) < 0.6 && abs(got.minY - want.minY) < 0.6
                && abs(got.width - want.width) < 0.6 && abs(got.height - want.height) < 0.6
            let size = "\(Int(got.width.rounded()))×\(Int(got.height.rounded()))"
            guard close else {
                let target = "\(Int(want.width.rounded()))×\(Int(want.height.rounded()))"
                return "\(name) \(size) WRONG (expected \(target) at "
                    + "\(Int(want.minX.rounded())),\(Int(want.minY.rounded())))"
            }
            return "\(name) \(size) ok"
        }

        // Pulled up and right by 300 with a 16:9 lock: the height is what the
        // hand moved, so the lock drives the width and the corner runs ahead of
        // the pointer sideways. That is the same rule a fresh drag uses, and it
        // is the reason this expectation is 533 wide and not 400.
        let corner = CaptureSurface.resized(wide, by: .topRight, to: NSPoint(x: 500, y: 400),
                                            aspect: .sixteenNine, within: bounds)
        let side = CaptureSurface.resized(wide, by: .right, to: NSPoint(x: 600, y: 999),
                                          aspect: .sixteenNine, within: bounds)
        // Growing sideways around its own centre line, from a frame already
        // against the right edge of the screen: the width has to stop where the
        // screen does and the height follow it back down.
        let narrow = CGRect(x: 900, y: 100, width: 90, height: 160)
        let room = CaptureSurface.resized(narrow, by: .top, to: NSPoint(x: 945, y: 400),
                                          aspect: .nineSixteen, within: bounds)
        let free = CaptureSurface.resized(wide, by: .left, to: NSPoint(x: 40, y: 0),
                                          aspect: .free, within: bounds)
        let floor = CaptureSurface.resized(wide, by: .right, to: NSPoint(x: 50, y: 0),
                                           aspect: .free, within: bounds)
        let moved = CaptureSurface.moved(wide, from: NSPoint(x: 200, y: 200),
                                         to: NSPoint(x: -50, y: 900), within: bounds)

        let cases = [
            check("corner", corner, CGRect(x: 100, y: 100, width: 533.333, height: 300)),
            check("side", side, CGRect(x: 100, y: 71.875, width: 500, height: 281.25)),
            check("edge", room, CGRect(x: 890, y: 100, width: 110, height: 195.555)),
            check("free", free, CGRect(x: 40, y: 100, width: 460, height: 225)),
            check("floor", floor, CGRect(x: 100, y: 100, width: 8, height: 225)),
            check("move", moved, CGRect(x: 0, y: 575, width: 400, height: 225)),
        ]
        return "capture frame: " + cases.joined(separator: ", ")
    }

    /// The long capture, checked against a page that was never on screen.
    ///
    /// The hard part of a hand-scrolled long capture is not the stitching, it is
    /// knowing how far each frame moved — and a measuring mistake does not look
    /// like a mistake, it looks like a picture with a slightly wrong seam, which
    /// is the kind of thing nobody notices until it is published.
    ///
    /// So the frames come from a made-up page with known seams: three windows of
    /// a 300 × 1200 sheet, taken 300 apart. Everything after that is the
    /// implementation's own arithmetic. The five claims:
    ///
    /// - the measured advance is 300 twice, in the right direction;
    /// - the stitched picture is the same height as the content it covers;
    /// - it looks like that content (mean difference against the original);
    /// - an identical frame is "still" and a frame from above is "backwards",
    ///   neither of which may be stitched;
    /// - a frame so far down that almost nothing overlaps is refused rather than
    ///   guessed at — measured on a real probe, Vision answered 380 with 45, a
    ///   number with the right sign that would have silently dropped 335 pixels.
    private static func longLine() -> String {
        let page = syntheticPage(width: 300, height: 1200)
        func window(_ top: Int) -> CGImage {
            page.cropping(to: CGRect(x: 0, y: top, width: 300, height: 400))!
        }
        let first = window(0), second = window(300), third = window(600)

        var parts: [String] = []

        let moves = [LongStitcher.advance(from: first, to: second),
                     LongStitcher.advance(from: second, to: third)]
        let shown = moves.map { $0.map(String.init) ?? "nil" }
        parts.append("advance \(shown.joined(separator: "/"))"
            + (moves == [300, 300] ? " ok" : " WRONG (expected 300/300)"))

        let stitcher = LongStitcher()
        stitcher.start(first)
        let one = stitcher.append(second)
        let two = stitcher.append(third)
        let stitched = stitcher.image()
        let wanted = page.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 1000))
        let difference = stitched.flatMap { made in
            wanted.flatMap { LongStitcher.meanDifference(made, $0) }
        }

        let sizes = stitched.map { "\($0.width)×\($0.height)" } ?? "none"
        let close = (stitched?.width == 300 && stitched?.height == 1000)
            && (difference ?? 1) < 0.02
        let gap = difference.map { String(format: "%.4f", $0) } ?? "n/a"
        parts.append("stitched \(sizes) \(close ? "ok" : "WRONG (expected 300×1000)") (diff \(gap))")
        parts.append("steps \(isAdvanced(one, 300) && isAdvanced(two, 300) ? "ok" : "WRONG")")

        let idle = LongStitcher()
        idle.start(first)
        parts.append("still \(isStill(idle.append(first)) ? "ok" : "WRONG")")

        // Upward, which is the direction this mode used to refuse: the second
        // frame is taken above the first, so the picture has to grow by its top
        // — the first frame is where the gesture started, not the top of the
        // picture. 300..700 seen first, then 0..400, is 0..700.
        let upward = LongStitcher()
        upward.start(window(300))
        let upStep = upward.append(window(0))
        let upImage = upward.image()
        let upWanted = page.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 700))
        let upDifference = upImage.flatMap { made in
            upWanted.flatMap { LongStitcher.meanDifference(made, $0) }
        }
        let upSizes = upImage.map { "\($0.width)×\($0.height)" } ?? "none"
        let upGap = upDifference.map { String(format: "%.4f", $0) } ?? "n/a"
        let upClose = isAdvanced(upStep, -300) && upImage?.height == 700
            && (upDifference ?? 1) < 0.02
        parts.append("upwards \(upSizes) "
            + (upClose ? "ok" : "WRONG (expected -300 and 300×700, diff \(upGap))"))

        // Back and forth: down a screen, up a screen, down again. The picture is
        // a page, so this is 0..700 seen twice as often, not 0..1900 — and the
        // union is what has to come out.
        let wander = LongStitcher()
        wander.start(window(0))
        let downAgain = [wander.append(window(300)), wander.append(window(0)),
                         wander.append(window(300))]
        let wanderImage = wander.image()
        let wanderWanted = page.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 700))
        let wanderDifference = wanderImage.flatMap { made in
            wanderWanted.flatMap { LongStitcher.meanDifference(made, $0) }
        }
        let wanderSizes = wanderImage.map { "\($0.width)×\($0.height)" } ?? "none"
        let wanderGap = wanderDifference.map { String(format: "%.4f", $0) } ?? "n/a"
        let wanderMoves = downAgain.map { step -> Int? in
            if case .advanced(let moved) = step { return moved }
            return nil
        }
        let wanderClose = wanderMoves == [300, -300, 300] && wanderImage?.height == 700
            && (wanderDifference ?? 1) < 0.02
        parts.append("back and forth \(wanderSizes) "
            + (wanderClose ? "ok" : "WRONG (moves \(wanderMoves), diff \(wanderGap), expected 300/-300/300 and 300×700)"))

        let near = LongStitcher.advance(from: first, to: window(250))
        let far = LongStitcher.advance(from: first, to: window(380))
        // Two-sided on purpose: a refusal that refuses everything is not a
        // check, so 250 has to be measured and 380 has to be turned down.
        parts.append("overlap " + (near == 250 && far == nil ? "ok"
            : "WRONG (250 → \(near.map(String.init) ?? "nil"), 380 → \(far.map(String.init) ?? "nil"))"))

        return "capture long: " + parts.joined(separator: ", ")
    }

    /// The Done button is inside the bar, the bar is on the screen, and neither
    /// moves while the number beside it grows.
    ///
    /// Geometry rather than a click, because a click needs a pointer and this
    /// harness has none. What can be checked without one is the thing that would
    /// fail silently: the capsule is the window the controller lays over the
    /// bar, so a pill outside it, or a bar half off the screen, is a button that
    /// presses on nothing while looking perfectly normal.
    @MainActor
    private static func doneLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture done: no screen"
        }
        func bar(_ height: Int?) -> (capsule: NSRect, done: NSRect, close: NSRect)? {
            let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.previewLong = height
            return view.longBarOnScreen
        }

        guard let short = bar(1240) else {
            return "capture done: MISSING (a growing bar should carry a Done check)"
        }
        // The ordinary bar's own check is the yardstick: the check that ends a
        // reading must be that chip, not a pill whose width followed a word.
        let plain = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        plain.frame = NSRect(origin: .zero, size: screen.frame.size)
        plain.selectForTesting(CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 60,
                                     width: 200, height: 120))
        guard let chip = plain.shotBarOnScreen?.confirm else {
            return "capture done: MISSING (no check on the icon row to compare with)"
        }
        let inside = short.capsule.contains(short.done)
        let onScreen = screen.frame.contains(short.capsule)
        let sized = short.done.width == chip.width && short.done.height == chip.height
        var parts: [String] = []
        parts.append("check \(Int(short.done.width))×\(Int(short.done.height)) "
            + (inside && onScreen && sized ? "ok"
               : "WRONG (inside \(inside), on screen \(onScreen), "
                 + "same box as the bar's check \(sized))"))

        // The way out, beside the way on: inside the capsule, clear of the pill,
        // and the same box as it. Three buttons on one line are three buttons —
        // 30 × 26 each, four points apart — whatever they do (「距离大小、宽度、
        // 高度，理论上都应该是一样的」, 2026-11-13). Emphasis is the fill and the
        // mark; the plate is the plate.
        let exitInside = short.capsule.contains(short.close)
        let clear = !short.close.intersects(short.done)
        let exitSized = short.close.width == short.done.width
            && short.close.height == short.done.height
        parts.append("✕ \(Int(short.close.width))×\(Int(short.close.height)) "
            + (exitInside && clear && exitSized ? "ok"
               : "WRONG (inside \(exitInside), clear of the pill \(clear), sized \(exitSized))"))

        // The whole row, in the state that has all three of them: one width, one
        // height, one gap.
        //
        // Reported in three steps, the same evening: 「这个图标的大小也不一
        // 致」 → 「这三个按钮的距离也不一样大」 → 「距离大小、宽度、高度，理论
        // 上都应该是一样的」. Each was a different number before: 30 × 26 / 22 ×
        // 22 / 30 × 26, gaps of 4 / 10 / 4. A row where nothing agrees with
        // anything is three buttons standing next to each other, not a row.
        let readingSurface = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        readingSurface.frame = NSRect(origin: .zero, size: screen.frame.size)
        readingSurface.showTranslationForTesting("一", from: "one")
        guard let reading = readingSurface.readingBarOnScreen else {
            return "capture done: no reading bar"
        }
        let row = [reading.second, reading.close, reading.done]
        let sameBox = row.allSatisfy { abs($0.width - 30) < 0.5 && abs($0.height - 26) < 0.5 }
        let gaps = [reading.close.minX - reading.second.maxX,
                    reading.done.minX - reading.close.maxX]
        let evenGaps = gaps.allSatisfy { abs($0 - 4) < 0.5 }
        // Measured before they are printed: a string interpolation with a closure
        // inside it, broken across lines, does not compile.
        let boxesText = row.map { box in
            String(format: "%.0f×%.0f", box.width, box.height)
        }.joined(separator: "/")
        let gapsText = gaps.map { gap in String(format: "%.0f", gap) }.joined(separator: "/")
        parts.append("row \(boxesText), gaps \(gapsText) "
            + (sameBox && evenGaps ? "ok" : "WRONG (want three 30×26 boxes with 4 between them)"))

        // The three marks inside those plates, measured off a real drawing of
        // the folded bar.
        //
        // The plates are rectangles in a struct and easy to keep in step; the ink
        // inside them was three sizes — 14 points for the chips, 12 semibold for
        // the tick, and a hand-drawn cross with a 3.6-point arm — and nothing in
        // the build said so. So the bar is rasterised, each control's ground is
        // taken as its most common colour, and the height of everything that is
        // not that ground is measured the way an eye would see it.
        //
        // Two and a half points of spread, not one: SF Symbols are optically
        // balanced, not metrically equal, and the ✕ is drawn under its own box
        // on purpose — a diagonal reads bigger than the rectangle it occupies —
        // so 10.0 against the chips' 12.0 is the system's judgement, not a
        // mistake in this bar. What the check is for is a mark out of family:
        // the hand-drawn cross this replaced measured 8.6, three and a half
        // points under its neighbours, and that is what was reported.
        var marksText = "no bitmap"
        var marksOk = false
        if let rep = readingSurface.bitmapImageRepForCachingDisplay(in: readingSurface.bounds) {
            readingSurface.cacheDisplay(in: readingSurface.bounds, to: rep)
            let measured = [("both", reading.second), ("✕", reading.close),
                            ("✓", reading.done)].map { name, rect in
                (name, Self.inkHeight(of: rect, in: readingSurface, rep: rep))
            }
            let heights = measured.compactMap { $0.1 }
            marksText = zip(measured.map { $0.0 }, measured.map { $0.1 })
                .map { "\($0) \($1.map { String(format: "%.1f", $0) } ?? "none")" }
                .joined(separator: " ")
            if heights.count == 3, let low = heights.min(), let high = heights.max() {
                marksOk = low >= 9 && high - low <= 2.5
            }
        }
        parts.append("marks \(marksText) " + (marksOk ? "ok" : "WRONG (want three heights within 2.5 pt, none under 9)"))

        // Two heights an order of magnitude apart: the readout gains a digit, and
        // the pill must not follow it. It is anchored to the far edge of the slot
        // for exactly this reason.
        let steady = bar(99999).map { $0.done == short.done } ?? false
        parts.append("steady \(steady ? "ok" : "WRONG (moved with the readout)")")

        // A note mid-capture — too fast to follow, or the ceiling reached — must
        // not resize the capsule. The pill is anchored to its far edge, so a
        // capsule that widens by a word slides the pill by a word, at the one
        // moment somebody is already reaching for it. Every note the stitcher
        // can say is measured whether or not it is showing, which is what makes
        // this hold; this line is what checks it stays that way.
        var capsuleOfNoted: NSRect?
        for note in LongStitcher.notes {
            let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.previewLong = 1240
            view.previewNote = note
            guard let moved = view.longBarOnScreen?.capsule else {
                capsuleOfNoted = nil
                break
            }
            if capsuleOfNoted == nil { capsuleOfNoted = moved }
            if moved != short.capsule { capsuleOfNoted = moved; break }
        }
        parts.append("note steady "
            + (capsuleOfNoted == short.capsule ? "ok" : "WRONG (a note resized the bar)"))

        parts.append("absent \(bar(nil) == nil ? "ok" : "WRONG (a plain capture has no Done pill)")")

        // A press delivered into the window the controller would make. This
        // covers the view, the hit and the closure — everything except the
        // window server. If a real click still does nothing while this passes,
        // the press is not reaching the window at all, which is a different bug
        // in a different place.
        //
        // Ordered in first, because a window that is not on screen drops mouse
        // events on the floor and the press would fail for the wrong reason. It
        // draws nothing, so this flashes nothing.
        let panel = LongBarPanel(capsule: short.capsule, done: short.done, close: short.close)
        panel.orderFrontRegardless()
        let settle = Date().addingTimeInterval(0.35)
        while Date() < settle {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        func press(_ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                                 modifierFlags: [], timestamp: 0,
                                                 windowNumber: panel.windowNumber,
                                                 context: nil, eventNumber: 1,
                                                 clickCount: 1, pressure: 1)
            else { return }
            panel.sendEvent(event)
        }
        var onPill = false
        var besidePill = false
        var onCross = false
        panel.onDone = { onPill = true }
        press(NSPoint(x: short.done.midX - short.capsule.minX,
                      y: short.done.midY - short.capsule.minY))
        panel.onDone = { besidePill = true }
        press(NSPoint(x: 5, y: short.done.midY - short.capsule.minY))
        // The ✕ answers instead of the pill, not as well as it: the two are one
        // point apart in intent and a press that lands on one must not run the
        // other.
        panel.onClose = { onCross = true }
        press(NSPoint(x: short.close.midX - short.capsule.minX,
                      y: short.close.midY - short.capsule.minY))
        panel.orderOut(nil)
        // The verdict is the press. What the window server thinks of the window
        // rides along in the failure text, because "the click did nothing" has
        // two very different repairs behind it.
        parts.append("click " + (onPill ? "ok" : "WRONG (a press on the pill did nothing; "
            + "visible \(panel.isVisible), key-can \(panel.canBecomeKey), "
            + "screen-covered \(!panel.occlusionState.contains(.visible)))"))
        parts.append("beside \(besidePill ? "WRONG (a press beside it finished the capture)" : "ok")")
        parts.append("cross " + (onCross && !besidePill ? "ok"
            : "WRONG (the ✕ closed: \(onCross), but the pill also fired: \(besidePill))"))

        // The press without the scrolling. Entering a long capture and pressing
        // Done without having scrolled at all — or after scrolling the wrong way,
        // so nothing was ever stitched — is the case where the pill is most
        // likely to be quietly refused, and it is the one nobody thinks to try
        // after a successful long capture. The pill's presence is already proven
        // above with an empty stitcher; this is the other half: what the press
        // then does. It must be an ordinary picture, never nothing.
        let none = CaptureSurface.longDecision(frames: 0, hasRegion: true)
        let one = CaptureSurface.longDecision(frames: 1, hasRegion: true)
        let many = CaptureSurface.longDecision(frames: 4, hasRegion: true)
        let bare = CaptureSurface.longDecision(frames: 1, hasRegion: false)
        parts.append("no scroll " + (none == .ordinary && one == .ordinary ? "ok"
            : "WRONG (0 frames → \(none), 1 frame → \(one); both should finish as a plain shot)"))
        parts.append("scrolled " + (many == .picture ? "ok" : "WRONG (4 frames → \(many))"))
        parts.append("no area " + (bare == .nothing ? "ok" : "WRONG (→ \(bare), expected nothing)"))
        let reads = bar(1240) != nil
        parts.append("pill without scrolling " + (reads
            ? "ok" : "WRONG (the pill depends on the frame count)"))

        return "capture done: " + parts.joined(separator: ", ")
    }

    /// The height of what is drawn inside one control, in points.
    ///
    /// The ground is that control's own most common colour rather than a
    /// constant, because the three controls stand on three different grounds: a
    /// pale tick on clay, a grey ✕ on a grey plate, near-black ink on the same
    /// grey. The rect is inset two points before anything is counted, so the
    /// plate's antialiased edge against the capsule is never read as ink.
    ///
    /// Threshold at 0.12 per channel: the plate itself is a ten-percent wash over
    /// the capsule, about a tenth away from it, and ink is at least four tenths
    /// away from the plate. A wash counted as ink would measure the plate, not
    /// the mark.
    ///
    /// The four corners are then skipped. A plate has a seven-point radius, so
    /// the two-point inset still leaves a crescent of capsule at each corner —
    /// invisible against a grey plate (a tenth away) and three tenths away from
    /// clay, which is why the check measured 22.5 points of "ink" the first time
    /// this was written: it had measured the whole plate. Six points of corner is
    /// more than the radius leaves uncovered and less than the margin every mark
    /// keeps from it.
    @MainActor
    private static func inkHeight(of rect: NSRect, in view: NSView,
                                  rep: NSBitmapImageRep) -> CGFloat? {
        guard view.bounds.width > 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let local = rect.offsetBy(dx: -view.bounds.minX, dy: -view.bounds.minY)
        // The rep's rows run down from the top; the view's y runs up from the
        // bottom. One flip, here, so nothing below has to think about it.
        let left = max(0, Int((local.minX + 2) * scale))
        let right = min(rep.pixelsWide - 1, Int((local.maxX - 2) * scale))
        let top = max(0, Int((view.bounds.height - local.maxY + 2) * scale))
        let bottom = min(rep.pixelsHigh - 1, Int((view.bounds.height - local.minY - 2) * scale))
        guard left < right, top < bottom else { return nil }
        var counts: [String: Int] = [:]
        var samples: [(row: Int, colour: NSColor)] = []
        func key(_ colour: NSColor) -> String {
            String(format: "%.2f/%.2f/%.2f", colour.redComponent,
                   colour.greenComponent, colour.blueComponent)
        }
        for row in top...bottom {
            for column in left...right {
                let x = CGFloat(column) / scale
                let y = view.bounds.height - CGFloat(row) / scale
                let atLeft = x - local.minX < 6, atRight = local.maxX - x < 6
                let atBottom = y - local.minY < 6, atTop = local.maxY - y < 6
                if (atLeft || atRight) && (atBottom || atTop) { continue }
                guard let colour = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)
                else { continue }
                counts[key(colour), default: 0] += 1
                samples.append((row, colour))
            }
        }
        guard let commonest = counts.max(by: { $0.value < $1.value })?.key,
              let ground = samples.first(where: { key($0.colour) == commonest })?.colour
        else { return nil }
        var first = Int.max, last = -1
        for sample in samples {
            let delta = max(abs(sample.colour.redComponent - ground.redComponent),
                            max(abs(sample.colour.greenComponent - ground.greenComponent),
                                abs(sample.colour.blueComponent - ground.blueComponent)))
            if delta > 0.12 {
                first = min(first, sample.row)
                last = max(last, sample.row)
            }
        }
        guard last >= 0 else { return nil }
        return CGFloat(last - first + 1) / scale
    }

    /// The third mode: a button for it, a bar that behaves, and a reader that
    /// actually reads.
    ///
    /// The last one is the check worth having. A `VNRecognizeTextRequest` whose
    /// languages did not load does not throw — it returns no results, which is
    /// exactly what a picture of an empty page returns. So a broken reader and
    /// an empty picture give the same answer, and the app would look like it
    /// simply cannot see: on every picture, for ever, with nothing red anywhere.
    /// Handing it a picture whose words are known is the only way to tell.
    @MainActor
    private static func textLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture text: no screen"
        }
        var parts: [String] = []
        let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        guard let shot = view.shotBarOnScreen else {
            return "capture text: MISSING (the bar should carry a 识别 button)"
        }
        let inside = shot.capsule.contains(shot.read)
        // Ahead of the checkmark, which is the last thing in the row.
        let beforeConfirm = shot.read.maxX <= shot.confirm.minX
        // A chip, not a word: 30 × 26 is the editor's box and the one every
        // neighbouring symbol sits in.
        let sized = shot.read.height == 26 && shot.read.width >= 30
        parts.append("button \(Int(shot.read.width))×\(Int(shot.read.height)) "
            + (inside && beforeConfirm && sized ? "ok"
               : "WRONG (inside \(inside), left of the check \(beforeConfirm), sized \(sized))"))

        // A reading does not get the bar's own window. That window exists
        // because a long capture's overlay ignores the mouse; a reading's does
        // not, and a panel laid over the bar would eat the ✕ and the 确认 it
        // covers.
        view.previewReading = "one\ntwo"
        let wantsPanel = view.longBarOnScreen != nil
        parts.append("no panel " + (wantsPanel
            ? "WRONG (a reading asked for the long capture's window)" : "ok"))

        // 译 is a door of its own beside 识别, not a switch on a finished
        // reading: one puts the words on the line, the other puts them on the
        // screen and keeps nothing. Two doors, one capsule.
        //
        // It carries a value now — the language a press answers in — so it is
        // one of the two wide chips at the start of the row rather than one of
        // the four squares, and it sits before 长图 instead of after 选文字.
        let heldT = shot.capsule.contains(shot.language)
        let beforeCheck = shot.language.maxX <= shot.confirm.minX
        let beforeLong = shot.language.maxX <= shot.long.minX
        let afterRatio = shot.ratio.maxX <= shot.language.minX
        // The chevron is inside the chip and at its right end: the menu has to
        // be reachable without covering the half that translates.
        let menuInside = shot.language.contains(shot.languageMenu)
        let menuAtTheEnd = abs(shot.languageMenu.maxX - shot.language.maxX) <= 1
        let sizedT = shot.language.height == 26 && shot.language.width > 30
        parts.append("translate \(Int(shot.language.width))×\(Int(shot.language.height)) "
            + (heldT && beforeCheck && beforeLong && afterRatio && menuInside
               && menuAtTheEnd && sizedT ? "ok"
               : "WRONG (inside \(heldT), left of the check \(beforeCheck), "
                 + "before 长图 \(beforeLong), after 比例 \(afterRatio), "
                 + "menu inside \(menuInside), menu at the end \(menuAtTheEnd), "
                 + "sized \(sizedT))"))

        // Two chips, two jobs, one press each: the globe picks a language and
        // asks nothing, and the chip beside it translates on the press. Both
        // halves of that split were corrected on 2026-11-13 — 「你那个选择语言没有
        // 这个功能，所以它只是选择」 and 「按 M 键或者点一下，理论上就该去翻译……我
        // 还必须再按一下回车键，这就是多余了」. So the first claim here is that
        // *nothing was asked*, and the second is that one press did ask.
        let area = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100,
                          width: 400, height: 200)
        /// The one press a hand makes to translate a drawn area: the chip that
        /// says where the words land, on its body rather than on its chevron.
        /// Kept in one place so every surface that wants a reading is asked for
        /// through the route the app asks for one.
        func pressTheDoor(_ surface: CaptureSurface) {
            _ = surface.takeBarClickForTesting(
                at: NSPoint(x: shot.presentation.minX + 12 - screen.frame.minX,
                            y: shot.presentation.midY - screen.frame.minY))
        }
        func translateDoor() -> CaptureSurface {
            let surface = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            surface.frame = NSRect(origin: .zero, size: screen.frame.size)
            surface.presentation = .card
            surface.selectForTesting(area)
            pressTheDoor(surface)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            surface.showReading("one\ntwo")
            return surface
        }

        var asked: String?
        var handedOver: String?
        /// Which door the read was started down. The ask is this, not
        /// `onTranslate`: the words are what the engine answers, and the
        /// question is whether it was asked at all.
        var started: [String] = []
        let door = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        door.frame = NSRect(origin: .zero, size: screen.frame.size)
        door.presentation = .card
        door.onTranslate = { asked = $0 }
        door.onFinishTranslation = { handedOver = $0 }
        door.onReadArea = { _ in started.append("card") }
        door.onReadInPlace = { _ in started.append("inPlace") }
        door.selectForTesting(area)
        let globe = door.takeBarClickForTesting(
            at: NSPoint(x: shot.language.midX - screen.frame.minX,
                        y: shot.language.midY - screen.frame.minY))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // Opened, and nothing else: not only "no request" but "no light", which
        // is the half a select box has to get right — a globe that lit `译`
        // would be claiming a mode it does not have.
        let listed = !door.languageRowsOnScreen.isEmpty
        let lit = door.pickedChipsForTesting.contains("translate")
        parts.append("the globe only picks "
            + (globe && listed && !lit && started.isEmpty && asked == nil ? "ok"
               : "WRONG (press \(globe), list \(listed), lit \(lit),"
                 + " asked \(started), handed \(asked ?? "nothing"))"))

        // And the chip beside it is one press, one request. The list is
        // dismissed first, because a press outside a panel spends itself
        // closing it — one of the two ways out, and the reason this check
        // presses the corner before the chip.
        _ = door.takeBarClickForTesting(at: NSPoint(x: 4, y: 4))
        pressTheDoor(door)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        parts.append("the chip asks at once " + (started == ["card"] ? "ok"
            : "WRONG (asked \(started))"))

        // The words come back from the engine, and the check hands them over.
        door.showReading("one\ntwo")
        parts.append("the words are asked for " + (asked == "one\ntwo" ? "ok"
            : "WRONG (asked \(asked ?? "nothing"))"))

        // And the check hands the translation over — the only useful way out of
        // this door. It no longer says 复制 or 确认: both were this one act.
        door.showTranslation("一\n二")
        if let pill = door.readingBarOnScreen {
            _ = door.takeBarClickForTesting(
                at: NSPoint(x: pill.done.midX - screen.frame.minX,
                            y: pill.done.midY - screen.frame.minY))
            // Deferred a turn on purpose, because in ordinary use that press
            // tears the capture down; the harness waits the turn rather than
            // assuming it is instant.
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            parts.append("copies " + (handedOver == "一\n二" ? "ok"
                : "WRONG (handed over \(handedOver ?? "nothing"))"))
        } else {
            parts.append("copies WRONG (no pill once a translation arrived)")
        }

        // Words already in the target language come back as `nothingToTranslate`
        // rather than as a translation. Its own answer — and never a bar left
        // saying 翻译中 with no pill and no way out, which is the state the log
        // caught nine presses deep.
        let stuck = translateDoor()
        stuck.showTranslationNoop()
        parts.append("already in it " + (stuck.readingBarOnScreen != nil ? "ok"
            : "WRONG (still translating, so the pill was gone)"))

        // A refusal must not leave the person holding nothing. The pill stays
        // and still hands over the words — a pill that disappears is a button
        // that looks broken, which is how "复制不生效" was reported.
        let refused = translateDoor()
        var rescued: String?
        refused.onFinishTranslation = { rescued = $0 }
        refused.showTranslationRefused(.unsure)
        if let pill = refused.readingBarOnScreen {
            _ = refused.takeBarClickForTesting(
                at: NSPoint(x: pill.done.midX - screen.frame.minX,
                            y: pill.done.midY - screen.frame.minY))
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            parts.append("refused still copies " + (rescued == "one\ntwo" ? "ok"
                : "WRONG (handed over \(rescued ?? "nothing"))"))
        } else {
            parts.append("refused still copies WRONG (the pill was gone)")
        }

        if let words = sampleWords() {
            let said = PictureText.recognize(in: words)
            let read = said.contains("123") && said.lowercased().contains("clothespeg")
            parts.append("reads " + (read ? "ok" : "WRONG (read \"\(said)\")"))
        } else {
            parts.append("reads WRONG (could not draw a picture for the reader)")
        }

        // A page in two columns, and the boxes have to stay in their columns.
        //
        // This is the check the 「错位」 report turned into (2026-11-13). Vision
        // normalises x by the picture's width and y by its height, while every
        // rule about "same line / same paragraph" is written in line heights —
        // so on a wide strip the two are not comparable, and the 150-point
        // gutter below reads as *narrower than a word space*. The rule that
        // allowed 1.5 line heights of gap therefore glued a line of the left
        // column to the line beside it in the right one, and their union box
        // spanned both: the cover is then a strip across the whole page and the
        // answer is drawn at its left edge, which is exactly what the picture
        // showed.
        //
        // Drawn rather than loaded, for the reason `sampleWords` gives: what has
        // to be true is the rule on this machine, not that a fixture is where it
        // was. The proportions are the ones that failed — a strip six times wider
        // than it is tall, and a gutter of nine percent of the width, which is
        // five times a word space at that size of type and 1.3 line heights.
        // Verified to fail: with the aspect conversion taken out of `square`, the
        // report reads `straddling ["16→826"]`.
        if let page = twoColumns() {
            let blocks = PictureText.recognizeBlocks(in: page.image)
            // The gutter's middle, in pixels: 150 wide, starting where the left
            // column's own text ends. A box that crosses it has been glued across
            // the columns, which is the failure.
            let middle = page.leftEdge + 75
            let straddling = blocks.filter {
                $0.box.minX * CGFloat(page.image.width) < middle
                    && $0.box.maxX * CGFloat(page.image.width) > middle
            }
            let stray = straddling.map { block in
                String(format: "%.0f→%.0f",
                       block.box.minX * CGFloat(page.image.width),
                       block.box.maxX * CGFloat(page.image.width))
            }
            parts.append("two columns \(blocks.count) blocks "
                + (blocks.count >= 2 && straddling.isEmpty ? "ok"
                   : "WRONG (straddling \(stray))"))
        } else {
            parts.append("two columns WRONG (could not draw the page)")
        }
        return "capture text: " + parts.joined(separator: ", ")
    }

    /// Two columns of text at the proportions that broke the grouping.
    ///
    /// Both columns are the same size of type on purpose: the rule that has to
    /// refuse this is the *gap*, not the type size, so a check that made the two
    /// columns different sizes would pass for the wrong reason.
    ///
    /// The gutter is measured from the drawn text rather than assumed: the number
    /// that matters is text-edge to text-edge, and that is not something a
    /// constant can know. 150 points is between 0.8 and 1.5 line heights, which
    /// is the window where the two rules disagree — inside it, the rule that
    /// compares raw normalised x merges the two columns and the rule that
    /// compares square units does not.
    private static func twoColumns() -> (image: CGImage, leftEdge: CGFloat)? {
        let width = 1600, height = 240
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        let attributes: [NSAttributedString.Key: Any] =
            [.font: NSFont.systemFont(ofSize: 22, weight: .regular),
             .foregroundColor: NSColor.black]
        // Same three rows on both sides, so the rows line up and the only
        // question left is whether they are treated as one line.
        let rows: [CGFloat] = [166, 126, 86]
        let leftLines = ["Diagnoses had been rising in the UK",
                         "for several years, and demand for",
                         "ADHD medication kept growing"]
        let rightLines = ["Generic methylphenidate rose as",
                          "dispensing fell for Concerta and",
                          "Xaggtin during the shortage"]
        let start: CGFloat = 20
        let leftEdge = start + (leftLines
            .map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0)
        for (index, y) in rows.enumerated() {
            (leftLines[index] as NSString).draw(at: NSPoint(x: start, y: y), withAttributes: attributes)
            (rightLines[index] as NSString).draw(at: NSPoint(x: leftEdge + 150, y: y),
                                                 withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }
        return (image, leftEdge)
    }

    /// Which language those words are in — the question the engine used to be
    /// left to answer for itself.
    ///
    /// This is the check the「无法翻译」report turned into. Given no source the
    /// engine may put up a sheet of its own asking which language, and a sheet
    /// nobody answers is a capture that says 翻译中… for ever. So the answer is
    /// decided here, and both halves of it are pinned: the languages that must
    /// be recognised, and the cases where saying "cannot tell" is the honest
    /// answer — above all short Latin text, which the underlying model reads as
    /// Turkish about as often as it reads it as English.
    private static func languageLine() -> String {
        var parts: [String] = []

        // Compared in the form the app actually hands over: `Locale.Language`
        // canonicalises, so `zh-Hans` reports itself as `zh` and `zh-Hant` as
        // `zh-TW`. The pair is the same pair either way, and asserting the
        // canonical form is what keeps this from passing on a label.
        func isOne(_ text: String, _ wanted: String) -> String {
            let got = SourceLanguage.guess(text)
            let want = Locale.Language(identifier: wanted)
            guard got?.minimalIdentifier == want.minimalIdentifier else {
                return "WRONG (\(text.prefix(10)) → \(got?.minimalIdentifier ?? "nil"), "
                    + "wanted \(want.minimalIdentifier))"
            }
            return "ok"
        }

        parts.append("simplified " + isOne("这是一段被识别出来的中文，用来检查语言判断。", "zh-Hans"))
        parts.append("traditional " + isOne("這是一段被識別出來的中文，用來檢查語言判斷。", "zh-Hant"))
        parts.append("english " + isOne("The quick brown fox jumps over the lazy dog.", "en"))
        // Kana before Han: a rule that only looked at Chinese characters would
        // call every Japanese page Chinese, which is the mistake this pins.
        parts.append("japanese " + isOne("これは画面から読み取った日本語の文章です。", "ja"))

        // No answer is the right answer for digits: there is nothing there to
        // translate, and inventing a language for it is how a wrong translation
        // gets made out of a column of numbers.
        let digits = SourceLanguage.guess("729 1240 38.5")?.minimalIdentifier
        parts.append("digits " + (digits == nil || digits == "en" ? "ok" : "WRONG (\(digits!))"))

        // Short selections are the ones people actually make — a word, a menu
        // item, a version number with one Chinese character in it. Eight
        // characters came back "cannot tell" once, and the capture with it.
        parts.append("mixed " + isOne("v1.2.3版", "zh-Hans") + "/" + isOne("OK 确定", "zh-Hans"))

        // The model reads a product name as Dutch and a fruit as Turkish; the
        // English thumb is what stops that, so it is worth a check of its own.
        parts.append("product name " + isOne("DeepSeek", "en"))

        let shortLatin = SourceLanguage.guess("apple")?.minimalIdentifier
        parts.append("short latin " + (shortLatin == nil || shortLatin == "en"
            ? "ok" : "WRONG (\(shortLatin!))"))

        let samePair = SourceLanguage.same(Locale.Language(identifier: "zh-Hans"),
                                           Locale.Language(identifier: "zh-Hans"))
        let differentScript = SourceLanguage.same(Locale.Language(identifier: "zh-Hans"),
                                                  Locale.Language(identifier: "zh-Hant"))
        // The exact pair that hung: Chinese words, a Chinese Mac, so the target
        // comes back as `zh-Hans-CN` while the detection says `zh`. They are the
        // same language, and saying so up front is what turns a 翻译中… that
        // never ends into 「这段已经是这种语言了」 in no time at all.
        let userCase = SourceLanguage.same(
            SourceLanguage.guess("这是一段被识别出来的中文，用来检查语言判断。"),
            Locale.Language(identifier: "zh-Hans-CN"))
        parts.append("same " + (samePair && !differentScript && userCase ? "ok"
            : "WRONG (same pair \(samePair), 简/繁 told apart \(!differentScript), "
              + "中文→中文系统 \(userCase))"))

        return "capture language: " + parts.joined(separator: ", ")
    }

    /// The button that brings the last frame back, and the memory behind it.
    ///
    /// Three claims, all able to be false. That what was remembered survives a
    /// round trip through the defaults intact: a rectangle that comes back
    /// eighty points to the left is a frame around the wrong thing, and nothing
    /// about it looks wrong. That a press on the button reaches the one thing it
    /// is for — the same "did the click land" question the pill had to answer.
    /// And that a frame put back is a frame like any other: the bar stays the
    /// shot bar, and a double-click inside it finishes the capture. That last
    /// one is the whole design — arriving instead of firing — so it is worth a
    /// synthetic click rather than a promise in a comment.
    @MainActor
    private static func againLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture again: no screen"
        }
        var parts: [String] = []
        // Put back afterwards: this runs inside the real app, in the real
        // defaults, and a self-test that forgot the person's last capture would
        // be a self-test that broke their next press of the button.
        let saved = LastCapture.stored
        defer { LastCapture.stored = saved }

        // Nothing remembered, no button. A button that is drawn and does
        // nothing is a button that reports the app as broken on its first run.
        LastCapture.stored = nil
        let empty = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        empty.frame = NSRect(origin: .zero, size: screen.frame.size)
        let hidden = empty.shotBarOnScreen?.again.isEmpty ?? true
        parts.append("hidden until used " + (hidden ? "ok"
            : "WRONG (shown with nothing to repeat)"))

        // And the key is silent in exactly that state, for the same reason the
        // button is absent: there is nothing to put back. Pressed here rather
        // than assumed, because a bare `A` with no guard is a key that ends a
        // capture that has nothing to restore.
        var keyedWithNothing = false
        empty.onAgain = { keyedWithNothing = true }
        if let down = press(0, "a") { empty.keyDown(with: down) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        parts.append("A silent until used " + (keyedWithNothing
            ? "WRONG (fired with nothing to repeat)" : "ok"))

        // Remembered, and it comes back the same.
        let rect = CGRect(x: screen.frame.minX + 120, y: screen.frame.minY + 90,
                          width: 320, height: 180)
        LastCapture.remember(.area, rect)
        let back = LastCapture.stored
        let same = back?.kind == .area && back?.rect == rect && back?.windowID == nil
        parts.append("remembers " + (same ? "ok"
            : "WRONG (got \(back.map { "\($0.kind) \($0.rect)" } ?? "nothing"))"))

        // What the press actually does is put the frame back — nothing fires.
        // Then the frame behaves like any other: a double-click inside it takes
        // the picture, and the bar is still the shot bar with the doors on it.
        let redrawn = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        redrawn.frame = NSRect(origin: .zero, size: screen.frame.size)
        var finished: CGRect?
        redrawn.onFinish = { finished = $0 }
        redrawn.restore(rect)
        let backAgain = redrawn.region == rect && redrawn.shotBarOnScreen != nil
        parts.append("frame back " + (backAgain ? "ok"
            : "WRONG (region \(String(describing: redrawn.region)), "
              + "shot bar \(redrawn.shotBarOnScreen == nil ? "gone" : "there"))"))
        if let click = click(at: NSPoint(x: rect.midX - screen.frame.minX,
                                         y: rect.midY - screen.frame.minY), count: 2) {
            redrawn.mouseDown(with: click)
            // The ending is deferred a turn — taking the picture closes the
            // window, and a view cannot be torn down inside the event it is
            // dispatching — so the harness waits instead of reading the answer
            // the instant the synthetic event returns. Reading it there said
            // "no capture happened" about a capture that had not happened *yet*,
            // which is this harness's own version of the bug it exists to catch.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            // Nothing was taken by `restore` itself — the capture only happened
            // because of the click that followed, which is the difference
            // between this button and the one the first draft had.
            parts.append("double-click takes it " + (finished == rect ? "ok"
                : "WRONG (finished \(String(describing: finished)))"))
        } else {
            parts.append("double-click takes it WRONG (no synthetic event)")
        }

        // The button, once there is something to repeat.
        let door = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        door.frame = NSRect(origin: .zero, size: screen.frame.size)
        var pressed = false
        door.onAgain = { pressed = true }
        guard let bar = door.shotBarOnScreen, !bar.again.isEmpty else {
            parts.append("button WRONG (not there once something was remembered)")
            return "capture again: " + parts.joined(separator: ", ")
        }
        // Pressed at the centre of the drawn rectangle and not at a point
        // worked out here, for the reason the bar's other buttons are: a button
        // drawn in one place and pressed in another is exactly this bug.
        _ = door.takeBarClickForTesting(
            at: NSPoint(x: bar.again.midX - screen.frame.minX,
                        y: bar.again.midY - screen.frame.minY))
        // Deferred a turn, like every other ending: the press tears the capture
        // down, and the harness waits rather than assuming it is instant.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let inside = bar.capsule.contains(bar.again)
        // 重载 now sits before 编辑, and 编辑 is the last button in the row.
        // 译 left this run when it gained a value, so the chip it follows is
        // 选文字.
        let afterRead = bar.read.maxX <= bar.again.minX
        let beforeEdit = bar.again.maxX <= bar.edit.minX
        let sized = bar.again.height == 26 && bar.again.width >= 30
        parts.append("button \(Int(bar.again.width))×\(Int(bar.again.height)) "
            + (pressed && inside && afterRead && beforeEdit && sized ? "ok"
               : "WRONG (pressed \(pressed), inside \(inside), "
                 + "after 选文字 \(afterRead), before 编辑 \(beforeEdit), sized \(sized))"))

        // The `A` in that chip's corner has to be heard and not merely drawn: a
        // letter on a button that does nothing is worse than no letter, because
        // the person concludes the app did not hear them.
        var keyed = false
        let byKey = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        byKey.frame = NSRect(origin: .zero, size: screen.frame.size)
        // The controller's half, played by hand. `A` only asks; what lights the
        // chip is the frame arriving, so a closure that set the light itself
        // would be this harness testing its own opinion instead of the app's.
        byKey.onAgain = {
            keyed = true
            byKey.restore(rect)
        }
        if let down = press(0, "a") { byKey.keyDown(with: down) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        parts.append("A takes it too " + (keyed ? "ok" : "WRONG (the key did nothing)"))

        // Lit because the frame is back — and still lit half a second later.
        // The light belongs to the frame, not to the press: the first version
        // treated a state as a blink and the user's correction was exact
        // (「它在出现的过程中，就应该一直是亮的」).
        let litOnArrival = byKey.againShowingForTesting
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let stillLit = byKey.againShowingForTesting
        parts.append("A lights it " + (litOnArrival && stillLit ? "ok"
            : "WRONG (lit \(litOnArrival), half a second later \(stillLit))"))

        // And a frame of one's own puts it out again: the light means *that*
        // frame, so a light that outlived it would be the same lie in the other
        // direction.
        byKey.selectForTesting(rect.offsetBy(dx: 40, dy: 0))
        parts.append("a new frame puts it out " + (byKey.againShowingForTesting
            ? "WRONG (still lit over a frame it did not bring back)" : "ok"))

        // The pill now hangs off the last button rather than off 译. They are
        // the same edge only while 重截 is absent, and the day they differ is
        // the day a press meant for one lands on the other.
        //
        // 译 is no longer the button it could collide with: it moved to the far
        // end of the row with the other value chip, so what the pill must clear
        // is 选文字 — the last symbol chip before the two that end the capture.
        door.selectForTesting(rect)
        // The chip that says where the words land is one press now, and it is
        // the press that asks — no list to dismiss first (2026-11-13).
        _ = door.takeBarClickForTesting(
            at: NSPoint(x: bar.presentation.minX + 12 - screen.frame.minX,
                        y: bar.presentation.midY - screen.frame.minY))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        door.showReading("one\ntwo")
        // The engine's answer has to arrive before the bar is a bar again:
        // while a translation is in flight the pill is deliberately absent.
        door.showTranslation("一\n二")
        if let reading = door.readingBarOnScreen {
            // The pill's right edge is the capsule's own inset, and nothing
            // reaches back over the symbols. It used to be levelled with 编辑,
            // because the word `esc` was drawn beyond the buttons and the pill
            // stopped where the buttons did — but that word is gone (the ✓ took
            // its place), and a pill anchored to the last button would now end
            // the collapsed bar a chip short of the edge, with a hole beside it.
            // A range rather than the padding constant, which is private to the
            // surface: what must not happen is the pill stopping short, and
            // 8…18 points is the band where it does not.
            let inset = reading.capsule.maxX - reading.done.maxX
            let atTheEnd = inset > 8 && inset < 18 && reading.done.minX > bar.read.maxX
            parts.append("pill at the end " + (atTheEnd ? "ok"
                : "WRONG (pill \(Int(reading.done.minX))…\(Int(reading.done.maxX)), "
                  + "capsule ends \(Int(reading.capsule.maxX)) (inset \(Int(inset))), "
                  + "选文字 ends at \(Int(bar.read.maxX)))"))
        } else {
            parts.append("pill at the end WRONG (no pill on a reading)")
        }

        return "capture again: " + parts.joined(separator: ", ")
    }

    /// Choosing, then taking: the one rule the whole capture now follows.
    ///
    /// Five claims, each of which can be false without anything looking wrong
    /// on a screen nobody is watching: a click on a window selects it and takes
    /// nothing; the second click — the double one — takes it; Space fills the
    /// frame in and *says* so rather than firing; Return then agrees with the
    /// filled frame; and 编辑 hands the controller the thing that was chosen —
    /// the window, not a rectangle around it, which is the difference between a
    /// covered window coming out whole and coming out covered.
    @MainActor
    private static func chooseLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture choose: no screen"
        }
        var parts: [String] = []
        let origin = screen.frame.origin
        // A window that is not there. Nothing in this test photographs
        // anything, so the id is a label and the frame is a place.
        let window = PickableWindow(id: 4242,
                                    frame: CGRect(x: origin.x + 200, y: origin.y + 160,
                                                  width: 480, height: 320),
                                    owner: "Harness")
        // The harness works in a surface's own coordinates, which are the
        // screen's shifted by the window's origin.
        func local(_ point: NSPoint) -> NSPoint {
            NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        }
        let middle = local(NSPoint(x: window.frame.midX, y: window.frame.midY))

        func surface() -> CaptureSurface {
            let made = CaptureSurface(backdrop: blank, screen: screen, windows: [window])
            made.frame = NSRect(origin: .zero, size: screen.frame.size)
            return made
        }

        // A click chooses. Nothing is taken, the frame is the window's own, and
        // the frame is not resizable — a window has no corners to pull.
        let one = surface()
        var taken: PickableWindow?
        one.onPick = { taken = $0 }
        if let down = click(at: middle), let up = click(at: middle) {
            one.mouseDown(with: down)
            one.mouseUp(with: up)
            let chose = one.region == window.frame && describe(one.target) == "window 4242"
            let quiet = taken == nil
            let still = !one.frameIsResizable
            // And the line does not offer what the frame cannot do: "drag an
            // edge to adjust" is true of a drawn frame and a lie about a
            // window, whose frame *is* the window's.
            let said = one.lineForTesting == L("Window · Return to capture")
            parts.append("click chooses " + (chose && quiet && still && said ? "ok"
                : "WRONG (region \(String(describing: one.region)), "
                  + "target \(describe(one.target)), taken \(quiet ? "no" : "YES"), "
                  + "resizable \(one.frameIsResizable), line \"\(one.lineForTesting)\")"))
        } else {
            parts.append("click chooses WRONG (no synthetic event)")
        }

        // The double-click is the same act as Return, and the only way a window
        // leaves this window.
        if let double = click(at: middle, count: 2) {
            one.mouseDown(with: double)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            parts.append("double-click takes it " + (taken == window ? "ok"
                : "WRONG (taken \(taken.map { String($0.id) } ?? "nil"))"))
        } else {
            parts.append("double-click takes it WRONG (no synthetic event)")
        }

        // Space fills the frame in and says so. It used to fire, which left the
        // frame unadjustable and gave the bar's doors nothing to act on.
        let space = surface()
        var whole: CGRect?
        var pickedWhole = false
        space.onFinish = { whole = $0 }
        space.onPick = { _ in pickedWhole = true }
        if let bar = press(49, " ") {
            space.keyDown(with: bar)
            let filled = space.region == screen.frame
            let said = space.lineForTesting == L("Whole screen · Return to capture")
            let quiet = whole == nil && !pickedWhole
            parts.append("space fills the frame " + (filled && said && quiet ? "ok"
                : "WRONG (region \(String(describing: space.region)), "
                  + "line \"\(space.lineForTesting)\", taken \(quiet ? "no" : "YES"))"))
            // And Return agrees with the frame it is looking at.
            if let enter = press(36, "\r") {
                space.keyDown(with: enter)
                parts.append("Return takes it " + (whole == screen.frame ? "ok"
                    : "WRONG (taken \(String(describing: whole)))"))
            } else {
                parts.append("Return takes it WRONG (no synthetic event)")
            }
        } else {
            parts.append("space fills the frame WRONG (no synthetic event)")
        }

        // 编辑 on a window arrives as the window. The bar is asked where its
        // button is rather than told: a button drawn in one place and pressed
        // in another is exactly this bug.
        var edited: CaptureTarget?
        let door = surface()
        door.onEdit = { edited = $0 }
        if let bar = door.shotBarOnScreen, !bar.edit.isEmpty {
            if let down = click(at: middle), let up = click(at: middle) {
                door.mouseDown(with: down)
                door.mouseUp(with: up)
            }
            _ = door.takeBarClickForTesting(at: local(NSPoint(x: bar.edit.midX,
                                                             y: bar.edit.midY)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            parts.append("编辑 a window " + (describe(edited) == "window 4242" ? "ok"
                : "WRONG (got \(describe(edited)))"))
        } else {
            parts.append("编辑 a window WRONG (no 编辑 button on the bar)")
        }

        // And on a drawn frame it arrives as that frame.
        let rect = CGRect(x: origin.x + 60, y: origin.y + 60, width: 240, height: 120)
        let frameDoor = surface()
        frameDoor.onEdit = { edited = $0 }
        frameDoor.selectForTesting(rect)
        if let bar = frameDoor.shotBarOnScreen, !bar.edit.isEmpty {
            _ = frameDoor.takeBarClickForTesting(at: local(NSPoint(x: bar.edit.midX,
                                                                   y: bar.edit.midY)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            parts.append("编辑 a frame " + (describe(edited) == "region 240×120" ? "ok"
                : "WRONG (got \(describe(edited)))"))
        } else {
            parts.append("编辑 a frame WRONG (no 编辑 button on the bar)")
        }

        // And `E` does the same thing without aiming at anything. Pressed on a
        // drawn frame rather than on an empty surface, because that is where the
        // key could quietly mean something else: the frame is already chosen, so
        // an `E` that opened a fresh full-screen editor would be a second
        // definition of the act.
        edited = nil
        let keyDoor = surface()
        keyDoor.onEdit = { edited = $0 }
        keyDoor.selectForTesting(rect)
        if let down = press(14, "e") { keyDoor.keyDown(with: down) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        parts.append("E edits it too " + (describe(edited) == "region 240×120" ? "ok"
            : "WRONG (got \(describe(edited)))"))

        return "capture choose: " + parts.joined(separator: ", ")
    }

    /// What a target is, as one word, for the harness to compare.
    ///
    /// `CaptureTarget` carries two incommensurable payloads, so it is described
    /// rather than compared: an id and a size are what a person would say.
    private static func describe(_ target: CaptureTarget?) -> String {
        switch target {
        case .none: return "nothing"
        case .region(let rect): return "region \(Int(rect.width))×\(Int(rect.height))"
        case .window(let picked): return "window \(picked.id)"
        }
    }

    /// The in-place repaint, checked as pixels: does the answer stay in the
    /// block it belongs to?
    ///
    /// This is the criterion for a bug reported on 2026-11-13 — 「原位置翻译，
    /// 有时候会显示不全」. The fit test measured the answer *inside* the box's
    /// width, and a string laid out to a width never reports more than that
    /// width: the test passed for a line twice the length of its box, the shrink
    /// loop never ran, and `draw(at:)` — which does not wrap — ran the words off
    /// the bubble and off the picture. Nothing in a still screenshot says which
    /// of the twelve layout decisions went wrong, so the check is the ink itself:
    /// no glyph may appear outside the block's own columns.
    private static func inPlaceFitLine() -> String {
        let width = 520, height = 140
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                         pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let drawing = NSGraphicsContext(bitmapImageRep: rep) else {
            return "capture answer in its box: no picture"
        }
        // A line of words on a panel, drawn the way a screenshot would carry it.
        // Two rectangles from the same numbers: the ink sits at 74…98 from the
        // bottom of an unflipped drawing, which is 42…66 from the top, and the
        // block is handed over in Vision's normalised bottom-left coordinates.
        let paper = NSColor(calibratedWhite: 0.98, alpha: 1)
        let original: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1),
        ]
        let inkX: CGFloat = 40, inkBottom: CGFloat = 74
        let inkWidth: CGFloat = 200, inkHeight: CGFloat = 24
        let box = NSRect(x: inkX, y: CGFloat(height) - inkBottom - inkHeight,
                         width: inkWidth, height: inkHeight)   // top-left, for the check
        NSGraphicsContext.current = drawing
        paper.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        ("This line of words" as NSString).draw(at: NSPoint(x: inkX, y: inkBottom),
                                               withAttributes: original)
        NSGraphicsContext.current = nil

        guard let base = rep.cgImage else { return "capture answer in its box: no picture" }
        // More than three times the width of the box it has to live in.
        let answer = "This line of words, in another language, takes a good deal more room than it had"
        let block = TextBlock(text: "This line of words",
                              box: CGRect(x: inkX / CGFloat(width),
                                          y: inkBottom / CGFloat(height),
                                          width: inkWidth / CGFloat(width),
                                          height: inkHeight / CGFloat(height)),
                              lineCount: 1)
        guard let painted = TranslatedImage.render(base: base, blocks: [block],
                                                   translations: [answer]) else {
            return "capture answer in its box: no render"
        }

        // Where the ink landed, read back out of the result.
        guard let read = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "capture answer in its box: no reader"
        }
        read.draw(painted, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = read.data?.assumingMemoryBound(to: UInt8.self) else {
            return "capture answer in its box: no pixels"
        }
        let bytes = read.bytesPerRow
        var outside = 0, inside = 0
        var deepest = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = pixels + y * bytes + x * 4
                guard p[0] < 128 else { continue }        // ink, not paper
                if Double(x) < box.minX - 1 || Double(x) > box.maxX + 1 {
                    outside += 1
                } else {
                    inside += 1
                    deepest = max(deepest, height - 1 - y)
                }
            }
        }
        let stayed = outside == 0 && inside > 0
        let grew = Double(deepest) > box.maxY        // wrapped, rather than cut on one line
        return "capture answer in its box "
            + (stayed && grew ? "ok"
               : "WRONG (\(outside) px outside, \(inside) inside, lowest \(deepest) vs \(Int(box.maxY)))")
    }

    /// The bar's chips, checked as geometry and as symbols.
    ///
    /// Three claims. Every symbol exists on this Mac — a name that has been
    /// renamed between two macOS releases draws as a blank box, and nothing else
    /// in a build would say so. Every chip is the same 30 × 26 box the editor's
    /// chips are, with the same four points between them, because two bars that
    /// differ by a point read as two different apps. And the two chips at the
    /// start are wider than a chip — the ratio one for its shape's name, the
    /// language one for the 16 points of chevron that open its menu.
    @MainActor
    private static func chipsLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture chips: no screen"
        }
        var parts: [String] = []

        // The language settings are pointed at scratch values for the whole of
        // this line, and not just for the menu's own checks.
        //
        // It started as the menu block's own business, because that block was
        // the only one that touched a preference. Then `T` began walking the
        // shortlist and *writing* the choice, as the menu does — and a key
        // pressed by a harness would have changed the 译成 of whoever ran it.
        // One seam for everything below is one thing to remember instead of two.
        var scratchList: [String]?
        var scratchCurrent: String?
        TranslationTargets.useStorageForTesting(
            readTarget: { scratchCurrent },
            writeTarget: { scratchCurrent = $0 },
            readList: { scratchList },
            writeList: { scratchList = $0 })
        defer { TranslationTargets.restoreRealStorage() }

        let missing = CaptureSymbol.all.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
        parts.append("symbols \(CaptureSymbol.all.count - missing.count)/\(CaptureSymbol.all.count) "
            + (missing.isEmpty ? "ok" : "WRONG (missing \(missing.joined(separator: ", ")))"))

        let surface = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        surface.frame = NSRect(origin: .zero, size: screen.frame.size)
        surface.selectForTesting(CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 60,
                                        width: 200, height: 120))
        guard let bar = surface.shotBarOnScreen else {
            return "capture chips: MISSING (the bar is not there)"
        }

        // In the order they are drawn — 编辑 last, 重载 one place before it when
        // it is there at all. The gaps are measured between neighbours, so a row
        // laid out in a different order shows up here as a 38-point hole.
        //
        // 译 and the chip beside it are not in this list: both are wide, and
        // both are checked with the ratio chip below.
        var chips = [bar.long, bar.read, bar.colour]
        if !bar.again.isEmpty { chips.append(bar.again) }
        chips.append(bar.edit)
        let boxes = chips.allSatisfy { $0.width == 30 && $0.height == 26 }
        let sizes = chips.map { "\(Int($0.width))×\(Int($0.height))" }.joined(separator: " ")
        parts.append("\(chips.count) 30×26 " + (boxes ? "ok" : "WRONG (\(sizes))"))

        // Asked as distances between edges rather than as a count: a chip that
        // grew by a point would move its neighbours and still pass a count.
        //
        // The three that are not four: the seam between `译` and the chip that
        // says where the translation goes (four — one question asked twice),
        // and the group seam in front of 长图 (ten). Two groups spaced like one
        // would be two groups nobody can see.
        var gaps: [Int] = [Int(bar.language.minX - bar.ratio.maxX),
                           Int(bar.presentation.minX - bar.language.maxX),
                           Int(bar.long.minX - bar.presentation.maxX)]
        for (left, right) in zip(chips, chips.dropFirst()) {
            gaps.append(Int(right.minX - left.maxX))
        }
        // Every seam in the icon row is four points, with the ten-point group
        // seam at the front.
        let expectedGaps = [4, 4, 10] + Array(repeating: 4, count: chips.count - 1)
        let wantedGaps = expectedGaps.map(String.init).joined(separator: "/")
        parts.append("gap \(gaps.map(String.init).joined(separator: "/")) "
            + (gaps == expectedGaps ? "ok" : "WRONG (wanted \(wantedGaps))"))

        // The three wide chips: wider than a chip, the same height, and together
        // at the start of the row — the ratio one, then the two about
        // translation: which language, and where the answer goes.
        let ratioWide = bar.ratio.width > 30 && bar.ratio.height == 26
        let languageWide = bar.language.width > 30 && bar.language.height == 26
        let presentationWide = bar.presentation.width > 30 && bar.presentation.height == 26
        let valuesAtStart = bar.ratio.maxX <= bar.language.minX
            && bar.language.maxX <= bar.presentation.minX
            && bar.presentation.maxX <= bar.long.minX
        let valuesFault = "wide \(ratioWide)/\(languageWide)/\(presentationWide),"
            + " together \(valuesAtStart)"
        parts.append("values \(Int(bar.ratio.width))+\(Int(bar.language.width))"
            + "+\(Int(bar.presentation.width))×26 "
            + (ratioWide && languageWide && presentationWide && valuesAtStart
               ? "ok" : "WRONG (\(valuesFault))"))

        // The far end is a button now, not a legend. The word `esc` used to sit
        // there and say something nobody could press; the checkmark says the one
        // thing this whole bar is for, and the gap in front of it is what tells
        // it apart from the six chips beside it.
        let confirm = bar.confirm
        let atTheEnd = confirm.minX > bar.edit.maxX + 8
        let confirmSized = confirm.width == 30 && confirm.height == 26
        parts.append("confirm \(Int(confirm.width))×\(Int(confirm.height)) "
            + (atTheEnd && confirmSized ? "ok"
               : "WRONG (after 编辑 \(atTheEnd), sized \(confirmSized))"))

        let inside = chips.allSatisfy { bar.capsule.contains($0) }
            && bar.capsule.contains(bar.ratio) && bar.capsule.contains(bar.language)
            && bar.capsule.contains(bar.presentation)
            && bar.capsule.contains(bar.presentationMenu)
            && bar.capsule.contains(bar.languageMenu) && bar.capsule.contains(confirm)
        parts.append("inside the capsule " + (inside ? "ok" : "WRONG"))

        // And the capsule itself inside the screen. A second value chip made the
        // row about seventy points wider, which is the kind of growth that is
        // invisible until the day the bar runs off both edges of a small display
        // and the shape chip is the half that goes missing.
        let onScreen = bar.capsule.minX >= screen.frame.minX
            && bar.capsule.maxX <= screen.frame.maxX
        parts.append("capsule \(Int(bar.capsule.width))pt "
            + (onScreen ? "ok" : "WRONG (runs off the screen)"))

        // The words the symbols gave up live in tool tips, and AppKit asks for
        // them through an informal protocol — a selector nothing checks. A typo
        // there is five mute buttons and no error, so the selector is asked for
        // by name.
        let owner = NSSelectorFromString("view:stringForToolTip:point:userData:")
        parts.append("tool tip owner " + (surface.responds(to: owner) ? "ok"
            : "WRONG (the view does not answer \(owner))"))

        // Arming a mode lights its chip, and nothing else. The report was exact:
        // `R` filled the ratio chip and `L`/`W` filled nothing, so three keys
        // looked like they had not been heard. Pressed with nothing chosen,
        // which is the state those keys exist for — with a frame already drawn
        // they act on it at once and there is no arming to see.
        //
        // `T` is not in this list any more. It opens a list and arms nothing
        // (「它只是选择」), so there is no chip to light; `M` is here because a
        // key pressed before the area really does wait for one, and the light is
        // how that wait is visible.
        var armed: [String] = []
        let wanted: [(UInt16, String)] = [(37, "long"), (13, "read"),
                                          (46, "presentation"), (34, "colour")]
        for (code, name) in wanted {
            let fresh = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            fresh.frame = NSRect(origin: .zero, size: screen.frame.size)
            guard let down = press(code, " ") else { armed.append("\(name):no-event"); continue }
            fresh.keyDown(with: down)
            let lit = fresh.pickedChipsForTesting
            armed.append(lit == [name] ? name: "\(name):WRONG(\(lit))")
        }
        let notArmed = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        notArmed.frame = NSRect(origin: .zero, size: screen.frame.size)
        let quiet = notArmed.pickedChipsForTesting.isEmpty
        parts.append("armed " + armed.joined(separator: "/")
            + (armed.allSatisfy { !$0.contains("WRONG") && !$0.contains("no-event") } && quiet
               ? " ok" : " WRONG (nothing chosen lit: \(quiet))"))

        // The chip that says where the translation goes: 46 wide like `译`,
        // right beside it, with its own 16-point chevron strip at the far end.
        // Two chips about one question, and the geometry says so.
        let presentationPlaced = bar.presentation.width == 46
            && bar.presentation.height == 26
            && bar.presentation.minX > bar.language.maxX
            && bar.presentation.maxX < bar.long.minX
            && bar.presentationMenu.width == 16
            && bar.presentationMenu.maxX == bar.presentation.maxX
            && bar.capsule.contains(bar.presentation)
        parts.append("where it goes " + (presentationPlaced ? "ok" : "WRONG"))

        // One press, one visible change, and it is a *setting*: choosing a row
        // moves the chip's symbol and asks no engine. Both halves are checked
        // because both were reported wrong in the version this replaces — a
        // half that only redrew, and a choice that ran a translation.
        //
        // The choice is remembered now (「我选了哪个，下一次就默认是这个」), so
        // the store is pointed at a scratch value for the length of these two
        // checks — never at the person's settings. Writing the real key and
        // putting it back failed once: this process ends in `exit(0)`, and a
        // preference written at the last moment is not always flushed, so the
        // restore went missing and `inPlace` stayed behind to break a check
        // three lines above it.
        var kept: String? = nil
        CaptureSurface.Presentation.useStorageForTesting(read: { kept },
                                                         write: { kept = $0 })
        let modeDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        modeDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        var asked: [String] = []
        modeDoor.onReadArea = { _ in asked.append("card") }
        modeDoor.onReadInPlace = { _ in asked.append("inPlace") }
        modeDoor.selectForTesting(CGRect(x: screen.frame.midX - 90,
                                         y: screen.frame.midY - 50,
                                         width: 180, height: 100))
        let defaultIsCard = modeDoor.presentationForTesting == "card"
        var opened = 0
        var choseInPlace = false
        var closed = false
        if let row = modeDoor.shotBarOnScreen {
            // The chevron, not the body: the body translates (that is the next
            // check), so the menu has to be reachable through the 16 points
            // that are only an arrow.
            let at = NSPoint(x: row.presentationMenu.midX - screen.frame.minX,
                             y: row.presentationMenu.midY - screen.frame.minY)
            _ = modeDoor.takeBarClickForTesting(at: at)
            let rows = modeDoor.presentationRowsOnScreen
            opened = rows.count
            if let inPlace = rows.first(where: { $0.way == "inPlace" }) {
                _ = modeDoor.takeBarClickForTesting(
                    at: NSPoint(x: inPlace.rect.midX - screen.frame.minX,
                                y: inPlace.rect.midY - screen.frame.minY))
                choseInPlace = modeDoor.presentationForTesting == "inPlace"
                closed = modeDoor.presentationRowsOnScreen.isEmpty
            }
        }
        parts.append("where it goes menu "
            + (defaultIsCard && opened == 2 && choseInPlace && closed && asked.isEmpty
               ? "ok"
               : "WRONG (default card \(defaultIsCard), rows \(opened),"
               + " chose in place \(choseInPlace), closed \(closed), engine \(asked))"))

        // And the next capture opens on that answer. Read through a fresh
        // surface rather than off the store, because the claim is about the
        // window, not about a preference file.
        let nextWindow = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        nextWindow.frame = NSRect(origin: .zero, size: screen.frame.size)
        let remembered = choseInPlace && nextWindow.presentationForTesting == "inPlace"
        CaptureSurface.Presentation.restoreRealStorage()
        parts.append("remembers where " + (remembered ? "ok"
            : "WRONG (next window \(nextWindow.presentationForTesting))"))

        // The chip says *where*, and its body is the press that acts on it —
        // the arrangement 2026-11-13 landed on: 「按 M 键或者点一下，理论上就该去
        // 翻译」. Both ways are checked by watching which callback fires, not by
        // reading a flag.
        var doors: [String] = []
        func presentationDoor(_ way: CaptureSurface.Presentation) -> String? {
            let surface = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            surface.frame = NSRect(origin: .zero, size: screen.frame.size)
            surface.presentation = way
            surface.onReadArea = { _ in doors.append("card") }
            surface.onReadInPlace = { _ in doors.append("inPlace") }
            surface.selectForTesting(CGRect(x: screen.frame.midX - 90,
                                            y: screen.frame.midY - 50,
                                            width: 180, height: 100))
            guard let row = surface.shotBarOnScreen else { return nil }
            let before = doors.count
            // The body: one press, and it goes down the door that is
            // remembered.
            _ = surface.takeBarClickForTesting(
                at: NSPoint(x: row.presentation.minX + 8 - screen.frame.minX,
                            y: row.presentation.midY - screen.frame.minY))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return doors.count == before + 1 ? doors.last : "asked \(doors.count - before)×"
        }
        let cardDoor = presentationDoor(.card)
        let inPlaceDoor = presentationDoor(.inPlace)
        parts.append("one press, two doors "
            + (cardDoor == "card" && inPlaceDoor == "inPlace" ? "ok"
               : "WRONG (card \(cardDoor ?? "none"), in place \(inPlaceDoor ?? "none"))"))

        // The two keys are still two different acts. `T` is the globe: it
        // changes which language, and never asks the engine — walking the list
        // is a setting, not a request (it opened the list until 2026-11-13;
        // what it does changed, what it must *not* do did not). `M` is the chip
        // beside it: with an area drawn it translates on the press — 「按 M 键的
        // 话就应该直接去做翻译」 — and what has to differ between the two is
        // exactly that.
        var byKey: [String: [String]] = [:]
        for code in [UInt16(17), 46] {
            var went: [String] = []
            let surface = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            surface.frame = NSRect(origin: .zero, size: screen.frame.size)
            surface.presentation = .inPlace
            surface.onReadInPlace = { _ in went.append("inPlace") }
            surface.selectForTesting(CGRect(x: screen.frame.midX - 90,
                                            y: screen.frame.midY - 50,
                                            width: 180, height: 100))
            if let down = press(code, "?") { surface.keyDown(with: down) }
            byKey["\(code)"] = went
        }
        let tQuiet = byKey["17"]?.isEmpty == true
        let mAsks = byKey["46"] == ["inPlace"]
        parts.append("T picks, M asks " + (tQuiet && mAsks ? "ok"
            : "WRONG (T asked \(byKey["17"] ?? []), M asked \(byKey["46"] ?? []))"))

        // And the light is a pixel, not a flag. One chip can fill here, and the
        // globe's must not: `M` pressed before an area is the one armed state
        // translation still has, while selecting a language is not a mode.
        func clays(_ rect: NSRect, _ rep: NSBitmapImageRep, _ view: CaptureSurface) -> Bool {
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
            let x = Int((rect.minX + 5 - screen.frame.minX) * scale)
            let y = Int((view.bounds.height - (rect.midY - screen.frame.minY)) * scale)
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return colour.redComponent - colour.blueComponent > 0.2
        }
        func fills(_ armed: String?) -> (presentation: Bool, translate: Bool)? {
            let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.selectForTesting(CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 60,
                                        width: 200, height: 120))
            view.armForTesting(armed)
            guard let row = view.shotBarOnScreen,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return (clays(row.presentation, rep, view), clays(row.language, rep, view))
        }
        let byM = fills("presentation")
        let quietChip = fills(nil)
        let chipLight = byM?.presentation == true && byM?.translate == false
            && quietChip?.presentation == false && quietChip?.translate == false
        parts.append("M's chip fills " + (chipLight ? "ok"
            : "WRONG (M \(String(describing: byM)),"
            + " quiet \(String(describing: quietChip)))"))

        // `Y` was the language list for a fortnight and is gone: 「我觉得这个 Y 的
        // 快捷键没有意义，这就是手工选就行了」(2026-11-13). A key that is still
        // wired after being removed is worse than one that never existed, so the
        // letter is pressed and has to do nothing at all.
        let yDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        yDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        if let down = press(16, "y") { yDoor.keyDown(with: down) }
        let yLit = yDoor.pickedChipsForTesting
        let yRows = yDoor.languageRowsOnScreen.count
        parts.append("Y is quiet " + (yLit.isEmpty && yRows == 0 ? "ok"
            : "WRONG (lit \(yLit), rows \(yRows))"))

        // And a reading on screen is not a reason to refuse — the press drops
        // the old answer and asks again, in one press. 2026-11-13: the language
        // was changed after a result, the same key pressed, and nothing moved,
        // because the guard was `reading == nil`. Then for two rounds the key
        // only armed and a second press was needed, which is the 「多余」 this
        // pins: one press per ask, twice over.
        let againDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        againDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        againDoor.presentation = .inPlace
        var askedAgain = 0
        againDoor.onReadInPlace = { _ in askedAgain += 1 }
        againDoor.selectForTesting(CGRect(x: screen.frame.midX - 90,
                                          y: screen.frame.midY - 50,
                                          width: 180, height: 100))
        if let down = press(46, "m") { againDoor.keyDown(with: down) }
        againDoor.showInPlaceTranslation(nil, words: "一", boxes: [
            CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.08)])
        let firstAsk = askedAgain
        if let down = press(46, "m") { againDoor.keyDown(with: down) }
        parts.append("ask again " + (firstAsk == 1 && askedAgain == 2 ? "ok"
            : "WRONG (asked \(firstAsk), then \(askedAgain))"))

        // The answer's lines are paired back to the picture's areas. The measured
        // failure (2026-11-13) is that a 7B model writes a space where the tab
        // was asked for — 「4 一键操作…」 — and a strict split dropped that line,
        // which painted nothing over it, which is half a screenshot left in
        // English. Three answers are fed through: numbered with spaces, wrapped
        // onto a second row, and with a literal backslash-t.
        let spaced = TranslationAPI.paired("1\t布局构建器\n2 对照\n3  原位置\n4 一键操作",
                                           count: 4)
        let wrapped = TranslationAPI.paired("1\t甲\n2\t乙\n丙", count: 2)
        let escaped = TranslationAPI.paired("1\\t甲", count: 1)
        let pairsRight = spaced == ["布局构建器", "对照", "原位置", "一键操作"]
            && wrapped == ["甲", "乙 丙"]
            && escaped == ["甲"]
        parts.append("answer pairs " + (pairsRight ? "ok"
            : "WRONG (spaced \(spaced), wrapped \(wrapped), escaped \(escaped))"))

        // An answer that is the question again is counted as no answer — but
        // only when the block was prose. The prompt tells the model to leave
        // product names, URLs and versions untouched, so those are the answer.
        let unchanged: [(String, String, Bool)] = [
            ("设置", "设置", true),                       // two Han characters
            ("一個月前", "一个月前", false),               // it did translate
            ("Tableau Studio", "Tableau Studio", false),   // a product name
            ("v2.3.0", "v2.3.0", false),                   // a version
            ("Café", "Café", false),                       // Latin-1, still a name
            ("This line of English words stayed as it was",
             "This line of English words stayed as it was", true),
        ]
        let toldApart = unchanged.allSatisfy { CaptureController.sameWords($0.0, as: $0.1) == $0.2 }
        parts.append("same words " + (toldApart ? "ok"
            : "WRONG (\(unchanged.map { "\($0.0)→\(CaptureController.sameWords($0.0, as: $0.1))" }))"))

        // 简体 ↔ 繁體 is converted here, not asked of a model. Measured twice on
        // 2026-11-13: asked for 繁體, the model answered 简体 — once in place, once
        // on the card, where it read 「这块区域里的文字，繁體中文」 over the same
        // text twice. ICU does it exactly, offline, in no time.
        let hans = Locale.Language(identifier: "zh-Hans")
        let hant = Locale.Language(identifier: "zh-Hant")
        let english = Locale.Language(identifier: "en")
        let backwards = ScriptConversion.convert("這裡有一隻鳥，麵條很好吃。", from: hant, to: hans)
        let forwards = ScriptConversion.convert("说明尾巴，面条。", from: hans, to: hant)
        let notThisPair = ScriptConversion.convert("设置", from: english, to: hant) == nil
        let blocks = ScriptConversion.convert(["说明", "尾巴"], from: hans, to: hant)
        let convertedRight = backwards == "这里有一只鸟，面条很好吃。"
            && forwards == "說明尾巴，麵條。"
            && notThisPair
            && blocks == ["說明", "尾巴"]
            // And the condition the capture actually meets: the source is
            // whatever `guess` says it is, not a language someone typed in.
            && SourceLanguage.guess("这不是新增一句「说明尾巴」。")
                .flatMap { ScriptConversion.convert("说明尾巴。", from: $0, to: hant) } == "說明尾巴。"
        parts.append("simplified to traditional " + (convertedRight ? "ok"
            : "WRONG (fwd \(forwards ?? "nil"), back \(backwards ?? "nil"), blocks \(blocks ?? []))"))

        // And an answer that never changed script is not a translation, even
        // when it differs by a character. `answer == input` was the old test and
        // it passed the 2026-11-13 answer, which was 简体 with one character
        // moved. Han against kana is deliberately not judged: Japanese is
        // written with both.
        let scriptTests: [(String, String, Locale.Language, Bool)] = [
            ("设置好了", "设置好了。", english, true),      // Chinese asked for English
            ("Settings are done.", "设置好了。", english, false),
            ("设置好了。", "设置好了。", hant, false),      // both Han — the converter's job
            ("설정 완료", "설정 완료。", hans, true),       // Korean asked for Chinese
            ("설정 완료", "设置完成", Locale.Language(identifier: "ko"), false),
            // A real Chinese answer that keeps product names is still a
            // translation. Measured 2026-11-16: Writing.of read 32 Han / 56
            // Latin as Latin, so the bar called a good answer untranslated.
            ("InputTables 不适用于沙盒扩展。InputTables 将 SuperTables 与 WriteBackExtreme 连接。",
             "InputTables is not available in sandbox extensions. "
             + "InputTables connects SuperTables with WriteBackExtreme.",
             hans, false),
        ]
        let scriptRight = scriptTests.allSatisfy {
            SourceLanguage.untouched($0.0, since: $0.1, into: $0.2) == $0.3
        }
        parts.append("script decides " + (scriptRight ? "ok"
            : "WRONG (\(scriptTests.map { "\($0.0)→\(SourceLanguage.untouched($0.0, since: $0.1, into: $0.2))" }))"))

        // And the bar says which language it is working in while it works. The
        // chip cannot: the name was taken off it on purpose. Without this line
        // a wrong target is invisible until the words come back in the wrong
        // language — 「我为什么翻译成英文，它翻译成的是繁体」 (2026-11-13).
        var scratchTarget: String? = "zh-Hant"
        TranslationTargets.useStorageForTesting(readTarget: { scratchTarget },
                                                writeTarget: { scratchTarget = $0 },
                                                readList: { nil }, writeList: { _ in })
        defer { TranslationTargets.restoreRealStorage() }
        let running = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        running.frame = NSRect(origin: .zero, size: screen.frame.size)
        running.showTranslationForTesting("一", from: "the words")
        let landed = running.lineForTesting
        running.markTranslatingForTesting()
        let inTradition = running.lineForTesting
        scratchTarget = "en"
        let inEnglish = running.lineForTesting
        parts.append("says where it goes "
            + (inTradition.contains("繁體中文") && inEnglish.contains("English")
               && landed.contains("繁體中文") ? "ok"
               : "WRONG (繁體「\(inTradition)」, en「\(inEnglish)」, landed「\(landed)」)"))

        // An engine that hands the English words back is a failure, not a noop.
        // Measured 2026-11-14 (qwen-mt-flash, one user message): six captures
        // in a row returned the question, and the bar called that 「已经是这种
        // 语言了」. A real Chinese answer must still land. The target goes
        // through the testing seam, never the real preference.
        scratchTarget = "zh-Hans"
        let echoDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        echoDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        echoDoor.showTranslationForTesting("", from: "Screenshot Preview")
        echoDoor.markTranslatingForTesting()
        echoDoor.showTranslation("Screenshot Preview")
        let echoedLine = echoDoor.lineForTesting
        let goodDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        goodDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        goodDoor.showTranslationForTesting("", from: "Screenshot Preview")
        goodDoor.markTranslatingForTesting()
        goodDoor.showTranslation("截图预览")
        let goodLine = goodDoor.lineForTesting
        let failedLine = L("Those words could not be translated")
        let noopLine = L("Those words are already in this language")
        let echoRight = echoedLine == failedLine
            && goodLine != failedLine && goodLine != noopLine
        parts.append("echoed back is a failure " + (echoRight ? "ok"
            : "WRONG (echo \"\(echoedLine)\", good \"\(goodLine)\")"))

        // The settings-page Test must not call a 200 with the question echoed
        // back a success. Same measured failure: Test said ok for as long as
        // translations did not happen.
        let echoCaught = TranslationAPI.answeredWithoutTranslating(
            TranslationAPI.testSample, into: hans)
        let chinesePasses = !TranslationAPI.answeredWithoutTranslating(
            "这条线是事物休息的地方。", into: hans)
        let emptyCaught = TranslationAPI.answeredWithoutTranslating("", into: hans)
        parts.append("test catches an echo " + (echoCaught && chinesePasses && emptyCaught ? "ok"
            : "WRONG (echo \(echoCaught), chinese \(chinesePasses), empty \(emptyCaught))"))
        scratchTarget = "en"

        // An area with nothing in another language says so, and gives the door
        // back. Reported 2026-11-13: the picture came back looking untouched and
        // the bar said nothing, which reads as a broken button. The second press
        // is the point — a reading left on screen is what stopped the mode from
        // being reachable, so a person could not change 译成 and try again.
        //
        // One press per ask: the answer that found nothing drops the reading, so
        // the same key asks again straight away.
        let noopDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        noopDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        noopDoor.presentation = .inPlace
        var wentInPlace = 0
        noopDoor.onReadInPlace = { _ in wentInPlace += 1 }
        noopDoor.selectForTesting(CGRect(x: screen.frame.midX - 90,
                                         y: screen.frame.midY - 50,
                                         width: 180, height: 100))
        if let down = press(46, "m") { noopDoor.keyDown(with: down) }
        noopDoor.inPlaceNothingToDo()
        let saidSo = noopDoor.lineForTesting == L("Those words are already in this language")
        if let down = press(46, "m") { noopDoor.keyDown(with: down) }
        parts.append("nothing to translate "
            + (saidSo && wentInPlace == 2 ? "ok"
               : "WRONG (said \(noopDoor.lineForTesting), asked \(wentInPlace))"))

        // And a request that never came back says so, rather than handing back
        // the same picture. A lost round trip cannot be seen in the picture —
        // the words are the words either way — so it is said on the bar, with
        // the same count a half-answered screen uses. 2026-11-13: the engine
        // timed out and the originals were painted back, which left a
        // screenshot that looked untouched: 「为什么也没有翻译，还是中文」.
        let lostDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        lostDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        lostDoor.showTranslationForTesting("", from: "Hello")
        lostDoor.showInPlaceTranslation(nil, words: "Hello", leftBehind: 3,
                                        boxes: [CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.08)])
        let lossLine = String(format: L("%d areas could not be translated"), 3)
        let saidLost = lostDoor.lineForTesting == lossLine
        parts.append("a lost request " + (saidLost ? "ok"
            : "WRONG (said \(lostDoor.lineForTesting), wanted \(lossLine))"))

        // The translated picture arrives the way the card's lines do: one block
        // at a time, top first (2026-11-13). The clock is the card's own, so
        // only the order is checked here — a still picture cannot show an
        // animation, but it can show the wrong order.
        let rowDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        rowDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        rowDoor.showTranslationForTesting("一", from: "one")
        rowDoor.showInPlaceTranslation(nil, words: "一", boxes: [
            CGRect(x: 0.1, y: 0.10, width: 0.6, height: 0.08),
            CGRect(x: 0.1, y: 0.80, width: 0.6, height: 0.08),
            CGRect(x: 0.1, y: 0.45, width: 0.6, height: 0.08),
        ])
        let tops = rowDoor.inPlaceBoxesForTesting.map(\.maxY)
        parts.append("in place top first "
            + (tops.count == 3 && tops == tops.sorted(by: >) ? "ok"
               : "WRONG (order \(tops))"))

        // The name a language is asked by. `minimalIdentifier` throws the script
        // away — `zh-Hant` comes back `zh-TW` — so the table's `繁體中文` was
        // never reached and both Chinese targets were sent as 「中文」, which a
        // model answers in Simplified. That is why 繁體 looked like it did
        // nothing (2026-11-13).
        let simplified = TranslationAPI.name(of: Locale.Language(identifier: "zh-Hans"))
        let traditional = TranslationAPI.name(of: Locale.Language(identifier: "zh-Hant"))
        parts.append("language names "
            + (simplified == "简体中文" && traditional == "繁體中文" ? "ok"
               : "WRONG (Hans \(simplified), Hant \(traditional))"))

        // A card's result has two things worth taking: the check hands over the
        // translation, and the chip beside it hands over both texts, so the two
        // can be read against each other. Asked for 2026-11-13: 「增加一个按钮，
        // 就变成双语一起复制，这样对照着去看？只复制文字，不是复制图片」.
        //
        // The same slot holds a picture on the in-place path, which is why the
        // chip is asked from the state and not from the mode: `inPlaceImage`
        // answers first, and only a card with two different strings gets the
        // texts. A chip that copied the same words twice would be a button
        // promising a second thing that is not there.
        let bothDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        bothDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        var handedBoth: String?
        bothDoor.onFinishTranslation = { handedBoth = $0 }
        bothDoor.showTranslationForTesting("一", from: "one")
        if let reading = bothDoor.readingBarOnScreen {
            let second = reading.second
            let placed = second.width == 30 && second.maxX < reading.close.minX
                && reading.capsule.contains(second)
            let named = bothDoor.secondExitNameForTesting == "both"
            // The folded bar has no room for a word, and this symbol is the one
            // the system does not have a glyph for: 「both texts」 has to be a
            // hover away or it is a guess (2026-11-13). Both tips are asked,
            // because the guard that used to sit here returned nothing at all
            // while the row was folded — a tip that is never offered is worse
            // than none, since the code looks like it offers one.
            let saidSecond = bothDoor.chipNameForTesting("second")
            let saidClose = bothDoor.chipNameForTesting("close")
            let tipped = saidSecond == L("Both texts · the words and their translation")
                && saidClose == L("Leave without taking it")
            // Pressed at the centre of the drawn rectangle, for the reason the
            // rest of this file presses there: a chip drawn in one place and
            // pressed in another is exactly the bug.
            _ = bothDoor.takeBarClickForTesting(
                at: NSPoint(x: second.midX - screen.frame.minX,
                            y: second.midY - screen.frame.minY))
            // Deferred a turn, as the check's own press is: in ordinary use
            // that press ends the capture.
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            parts.append("both texts "
                + (placed && named && tipped && handedBoth == "one\n\n一" ? "ok"
                   : "WRONG (placed \(placed), named "
                     + "\(bothDoor.secondExitNameForTesting ?? "none"), "
                     + "tips \(saidSecond ?? "none") / \(saidClose ?? "none"), "
                     + "handed over \(handedBoth ?? "nothing"))"))
        } else {
            parts.append("both texts WRONG (no reading bar)")
        }

        // And the in-place path keeps the picture in that slot — the order of
        // the two answers is what decides it, so it is worth one press.
        let pictureDoor = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        pictureDoor.frame = NSRect(origin: .zero, size: screen.frame.size)
        pictureDoor.showTranslationForTesting("一", from: "one")
        pictureDoor.showInPlaceTranslation(blank, words: "一", boxes: [
            CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.08),
        ])
        parts.append("picture wins "
            + (pictureDoor.secondExitNameForTesting == "picture"
               && pictureDoor.chipNameForTesting("second") == L("The translated picture")
               ? "ok"
               : "WRONG (got \(pictureDoor.secondExitNameForTesting ?? "none"), "
                 + "tip \(pictureDoor.chipNameForTesting("second") ?? "none"))"))

        // Wrapped lines become one sentence; a full stop begins the next one.
        // A join that ignored punctuation is what sent two halves of one
        // sentence to the engine as separate thoughts.
        let joined = PictureText.joinedForTesting([
            "Choose an area of the screen,",
            "then read it in place.",
            "A new sentence",
        ])
        parts.append("paragraph " + (joined ==
            "Choose an area of the screen, then read it in place.\nA new sentence"
            ? "ok" : "WRONG (\(joined))"))

        return "capture chips: " + parts.joined(separator: ", ")
    }

    /// The language menu behind the `译` chip's chevron.
    ///
    /// Four claims, none of which a picture of the bar would settle. It offers
    /// the shortlist that was configured and nothing else — a menu that quietly
    /// showed all ten would be a menu that ignored Settings. It offers them in
    /// the catalogue's order, because a list that rearranges itself is a list
    /// with no place to remember. It marks the one in force, which is a colour
    /// and therefore a pixel. And the chip does not change width when the answer
    /// changes, because the four symbols to its right would move with it.
    ///
    /// The setting itself is written and read back at the end: everything here
    /// goes through `UserDefaults`, and a menu drawn from a value that was never
    /// stored would pass every geometry check above.
    @MainActor
    private static func languagesLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture languages: no screen"
        }
        var parts: [String] = []
        // The harness runs on a real Mac with real preferences, so it points the
        // setting at a scratch value instead of writing the real one. Saving the
        // two values and putting them back was the first version and it lost
        // them: the restore is the last write of the process, the process ends
        // in `exit(0)`, and 译成 came out of a self-test run as `en` when it had
        // been 繁體. A test that quietly changes the app is not a test.
        var scratchList: [String]?
        var scratchCurrent: String?
        TranslationTargets.useStorageForTesting(
            readTarget: { scratchCurrent },
            writeTarget: { scratchCurrent = $0 },
            readList: { scratchList },
            writeList: { scratchList = $0 })
        defer { TranslationTargets.restoreRealStorage() }

        // Deliberately not the default three, and deliberately not in the order
        // they are written: a menu that echoed `fallback` would pass without
        // reading the setting at all.
        TranslationTargets.chosen = ["en", "ja", "zh-Hans"]
        TranslationTargets.current = "ja"

        func surface() -> CaptureSurface? {
            let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.selectForTesting(CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 60,
                                        width: 200, height: 120))
            return view.shotBarOnScreen == nil ? nil : view
        }

        guard let view = surface(), view.openPanelForTesting("language") else {
            return "capture languages: MISSING (no panel)"
        }
        let rows = view.languageRowsOnScreen
        let codes = rows.map(\.code)
        parts.append("offers \(codes.joined(separator: "/")) "
            + (codes == ["zh-Hans", "en", "ja"] ? "ok" : "WRONG (wanted zh-Hans/en/ja)"))

        // The current one, by pixel. Clay is the only thing in this window whose
        // red is that far from its blue; the panel behind it is the warm ground,
        // which is nearly grey in both appearances.
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "capture languages: MISSING (nothing was drawn)"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        func isClay(_ row: NSRect) -> Bool {
            let local = NSPoint(x: row.minX + 6 - screen.frame.minX,
                                y: row.midY - screen.frame.minY)
            guard let colour = rep.colorAt(x: Int(local.x * scale),
                                           y: Int((view.bounds.height - local.y) * scale))?
                .usingColorSpace(.sRGB) else { return false }
            return colour.redComponent - colour.blueComponent > 0.2
        }
        let markedCurrent = rows.first { $0.code == "ja" }.map { isClay($0.rect) } ?? false
        let othersPlain = rows.filter { $0.code != "ja" }.allSatisfy { !isClay($0.rect) }
        parts.append("current marked " + (markedCurrent && othersPlain ? "ok"
            : "WRONG (clay on ja \(markedCurrent), plain elsewhere \(othersPlain))"))

        // In the screen, and above the bar rather than over it.
        let capsule = view.shotBarOnScreen?.capsule ?? .zero
        let onScreen = rows.allSatisfy {
            screen.frame.contains($0.rect) && $0.rect.minY >= capsule.maxY
        }
        parts.append("on screen " + (rows.count == 3 && onScreen ? "ok"
            : "WRONG (\(rows.count) rows, on screen \(onScreen))"))

        // No word on the chip, so its width cannot depend on the language: 30
        // points of icon and 16 of chevron, whatever is in force. Compared
        // against the number as well as against itself — two chips that were
        // both wrong would pass "the same".
        let wide = view.languageChipWidthOnScreen
        TranslationTargets.current = "en"
        guard let other = surface() else { return "capture languages: MISSING (no second bar)" }
        let narrow = other.languageChipWidthOnScreen
        parts.append("width fixed \(Int(wide))pt "
            + (wide == narrow && wide == 46 ? "ok"
               : "WRONG (简体中文 \(Int(wide)), English \(Int(narrow)))"))

        // Both halves of the globe open the list, and neither translates: the
        // chip is a select box — 「其实它没有按钮的作用，只是一个选择框」 — so it
        // lights nothing either (`capture text`'s "the globe only picks" and
        // "the chip asks at once" pin the other half of that).
        guard let byClick = surface() else { return "capture languages: MISSING (no bar to press)" }
        let bar = byClick.shotBarOnScreen!
        _ = byClick.takeBarClickForTesting(
            at: NSPoint(x: bar.languageMenu.midX - screen.frame.minX,
                        y: bar.languageMenu.midY - screen.frame.minY))
        let opened = byClick.languageRowsOnScreen.count
        let byBody = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        byBody.frame = NSRect(origin: .zero, size: screen.frame.size)
        _ = byBody.takeBarClickForTesting(
            at: NSPoint(x: bar.language.minX + 12 - screen.frame.minX,
                        y: bar.language.midY - screen.frame.minY))
        let armedByBody = byBody.pickedChipsForTesting
        let bodyOpened = byBody.languageRowsOnScreen.count
        parts.append("globe opens · lights nothing "
            + (opened == 3 && bodyOpened == 3 && armedByBody.isEmpty ? "ok"
               : "WRONG (chevron rows \(opened), body rows \(bodyOpened),"
                 + " body armed \(armedByBody))"))

        // One panel at a time. Opening the shapes menu has to close this one by
        // construction rather than by anybody remembering to.
        _ = byClick.openPanelForTesting("ratio")
        let languageStillOpen = !byClick.languageRowsOnScreen.isEmpty
        parts.append("one panel " + (languageStillOpen
            ? "WRONG (the language menu survived the shapes menu)" : "ok"))

        // `T` walks the shortlist rather than opening it, the way `R` walks the
        // shapes (2026-11-13: 「用 T 只能跳转到"选择语言"的按钮，但是不能去切换
        // 语言…按 R 就可以直接跳」).
        //
        // Walked all the way round on purpose: a key that only ever moves one way
        // and stops, and a key that wraps, look identical after one press. The
        // last value is read back through the seam as well, because a language
        // chosen for this capture and forgotten by the next is not a setting —
        // and the note is asked for by name, since the chip carries no word and
        // this is the only thing on screen that says where it landed.
        TranslationTargets.chosen = ["zh-Hans", "en", "ja"]
        TranslationTargets.current = "zh-Hans"
        guard let walker = surface() else {
            return "capture languages: MISSING (no bar to walk)"
        }
        var walked: [String] = []
        var said: [String] = []
        for _ in 0..<4 {
            if let down = press(17, "t") { walker.keyDown(with: down) }
            walked.append(walker.languageForTesting)
            said.append(walker.saidNoteForTesting ?? "")
        }
        let shutWhileWalking = walker.languageRowsOnScreen.isEmpty
        // The note names the language, not its code: the sentence is read, and
        // 「译成 en」 is a sentence about a settings file.
        let landing = String(format: L("Now into %@"),
                             TranslationCatalogue.named("en")?.name ?? "en")
        parts.append("T walks \(walked.joined(separator: "→")) "
            + (walked == ["en", "ja", "zh-Hans", "en"] && shutWhileWalking
               && scratchCurrent == "en" && said.last == landing
               ? "ok"
               : "WRONG (walked \(walked), rows \(walker.languageRowsOnScreen.count),"
                 + " stored \(scratchCurrent ?? "nothing"), said \(said.last ?? "nothing"))"))

        // One language is not a list to walk. The key then opens the menu
        // instead of doing nothing: a key that is silent on some machines reads
        // as broken on those machines.
        TranslationTargets.chosen = ["ko"]
        guard let single = surface() else {
            return "capture languages: MISSING (no bar for the single case)"
        }
        if let down = press(17, "t") { single.keyDown(with: down) }
        let oneTarget = single.languageRowsOnScreen.count == 1
        let stayedPut = single.languageForTesting == "ko"
        parts.append("T with one target " + (oneTarget && stayedPut
            ? "ok" : "WRONG (rows \(single.languageRowsOnScreen.count),"
                     + " went to \(single.languageForTesting))"))

        // And the setting is a setting: written, read back, and never empty.
        // Through the seam, so what this proves is our getter and our setter —
        // the list that comes back ticked, deduplicated and in catalogue order.
        // That the value survives the process is `UserDefaults`'s guarantee and
        // not ours, and it is the one claim here worth giving up rather than
        // write into somebody's preferences to prove.
        TranslationTargets.chosen = ["ko"]
        let stored = TranslationTargets.chosen
        TranslationTargets.chosen = []
        let neverEmpty = TranslationTargets.chosen
        parts.append("stored \(stored.joined(separator: "/")) "
            + (stored == ["ko"] && !neverEmpty.isEmpty ? "ok"
               : "WRONG (read back \(stored), emptied to \(neverEmpty))"))

        return "capture languages: " + parts.joined(separator: ", ")
    }

    /// Whether the bar is drawn in the appearance it is drawn in.
    ///
    /// "暗色就是暗色，亮色就是亮色" is not a claim about a colour constant, it is a
    /// claim about pixels — and pixels only arrive by drawing. So the bar is
    /// drawn twice, once in aqua and once in darkAqua, and the capsule is
    /// sampled on a grid: the light one has to come out mostly bright with dark
    /// ink inside it, the dark one mostly dark with bright ink. A surface left
    /// hardcoded fails the first; an ink left hardcoded fails the second. Those
    /// are precisely the two mistakes this file exists to catch, and both of
    /// them look like nothing at all in a screenshot of the other appearance.
    @MainActor
    private static func styleLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture style: no screen"
        }
        var parts: [String] = []
        let cases: [(String, NSAppearance.Name, Bool)] = [
            ("light", .aqua, true), ("dark", .darkAqua, false),
        ]
        for (name, appearanceName, wantLight) in cases {
            let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.appearance = NSAppearance(named: appearanceName)
            view.selectForTesting(CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 60,
                                        width: 200, height: 120))
            guard let bar = view.shotBarOnScreen,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                parts.append("\(name) WRONG (nothing was drawn)")
                continue
            }
            view.cacheDisplay(in: view.bounds, to: rep)

            let capsule = bar.capsule.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
            var bright = 0, dark = 0, total = 0
            var x = capsule.minX + 4
            while x < capsule.maxX - 4 {
                var y = capsule.minY + 3
                while y < capsule.maxY - 3 {
                    // A bitmap is stored top-down; this view is not flipped, so
                    // the y has to be turned round before it is a pixel row.
                    let point = NSPoint(x: x * scale, y: (view.bounds.height - y) * scale)
                    if let colour = rep.colorAt(x: Int(point.x), y: Int(point.y))?
                        .usingColorSpace(.sRGB) {
                        let luminance = 0.2126 * colour.redComponent
                            + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
                        if luminance > 0.65 { bright += 1 }
                        if luminance < 0.35 { dark += 1 }
                        total += 1
                    }
                    y += 2
                }
                x += 2
            }
            guard total > 200 else {
                parts.append("\(name) WRONG (only \(total) samples)")
                continue
            }
            let brightShare = Double(bright) / Double(total)
            let darkShare = Double(dark) / Double(total)
            // Both numbers, because a bar that is one flat colour passes one of
            // them and the interesting failure — bright ground under white type
            // — is only visible in the pair.
            let surfaceOK = wantLight ? brightShare > 0.6 : darkShare > 0.6
            let inkOK = wantLight ? darkShare > 0.01 : brightShare > 0.01
            parts.append("\(name) \(Int(brightShare * 100))% light, \(Int(darkShare * 100))% dark "
                + (surfaceOK && inkOK ? "ok"
                   : "WRONG (surface \(surfaceOK), ink \(inkOK))"))
        }
        return "capture style: " + parts.joined(separator: ", ")
    }

    /// Whether the words are on screen at all, at the shapes a hand draws.
    ///
    /// Two failures this exists for, both reported on 2026-11-03 and both
    /// invisible to anyone reading the code: the words did not appear at all
    /// (the box they were laid into collapsed to `NSRect.null` and the draw
    /// returned before a glyph — the clipboard had them, the screen did not),
    /// and long words came out as `…` (the frame, not the type, was deciding the
    /// line width). The fix was to stop drawing inside the frame; what has to be
    /// true afterwards is a set of facts about the card, and each of them is
    /// checked here rather than argued about:
    ///
    /// - a card exists at all,
    /// - it covers the centre of the frame it belongs to (2026-11-04: the card
    ///   carries both languages, so it sits on the words rather than beside
    ///   them; only a frame that is the whole screen is allowed a corner),
    /// - it is inside the screen,
    /// - its width is the card's own 340–560 rather than the frame's,
    /// - it has ink in it — counted, not assumed.
    ///
    /// 14, 20 and 24 are the heights a frame round one line of small type comes
    /// to; 40 is a comfortable line; 60×60 is a word circled tightly; and the
    /// long paragraph is the case that used to be one line and an ellipsis.
    /// The staircase the words arrive on. A flat reveal — every line at once —
    /// is exactly the thing being avoided, so this check has to be able to fail
    /// without a window, a timer or a screenshot in the middle of an animation.
    private static func revealLine() -> String {
        let earlyTop = ResultReveal.alpha(row: 0, elapsed: 0.05)
        let earlyFourth = ResultReveal.alpha(row: 3, elapsed: 0.05)
        let midSecond = ResultReveal.alpha(row: 1, elapsed: 0.10)
        let doneTop = ResultReveal.alpha(row: 0, elapsed: 1)
        let doneFourth = ResultReveal.alpha(row: 3, elapsed: 1)
        let ordered = earlyTop > earlyFourth && earlyFourth == 0
            && midSecond > 0 && midSecond < 1
            && doneTop == 1 && doneFourth == 1
        let duration = ResultReveal.duration(rows: 4)
        let ends = duration >= ResultReveal.fade && duration < 1
        return "capture reveal: " + (ordered && ends
            ? String(format: "top first, all in %.2f s ok", duration)
            : "WRONG (top \(earlyTop), fourth \(earlyFourth), second \(midSecond), "
                + "done \(doneTop)/\(doneFourth), \(duration) s)")
    }

    /// The number in the middle of the bar answers "how long is this reading",
    /// and "19 characters" over four English words is not an answer. English
    /// and Spanish are counted in words; Chinese and Japanese, whose scripts
    /// have no spaces between words, stay on characters. The expected unit is
    /// looked up here rather than spelled out, so the check holds whichever
    /// language the app happens to be running in.
    private static func countLine() -> String {
        let wanted: [(String, Int, Bool)] = [
            ("The quick brown fox", 4, true),
            ("Hola, ¿cómo estás?", 3, true),
            ("Hello, world!", 2, true),
            ("敏捷的棕色狐狸跳过了懒狗", 12, false),
            ("素早い茶色の狐が怠け者の犬を飛び越えた", 19, false),
            ("Clothespeg 剪贴板", 14, false),
        ]
        var wrong: [String] = []
        for (text, number, inWords) in wanted {
            let expected = "\(number) \(inWords ? L("words") : L("characters"))"
            let said = ResultCount.label(for: text)
            if said != expected { wrong.append("[\(text)] → \(said), expected \(expected)") }
        }
        if ResultCount.label(for: "   ") != "" { wrong.append("blank is not empty") }
        let punctuation = "3 \(L("characters"))"
        if ResultCount.label(for: "!!!") != punctuation {
            wrong.append("punctuation fell back to \(ResultCount.label(for: "!!!"))")
        }
        return "capture count: " + (wrong.isEmpty
            ? "en/es/punctuation in words, zh/ja/mixed in characters ok"
            : "WRONG (" + wrong.joined(separator: "; ") + ")")
    }

    @MainActor
    private static func cardLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture card: no screen"
        }
        var parts: [String] = []

        func examine(_ name: String, region: CGRect, words: String?, translated: String? = nil,
                     allowOutside: Bool = false,
                     extra: ((NSRect, (NSRect) -> Int) -> String?)? = nil) {
            let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.appearance = NSAppearance(named: .aqua)
            view.selectForTesting(region)
            if let translated {
                view.showTranslationForTesting(translated, from: words)
            } else {
                view.showReadingForTesting(words)
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                parts.append("\(name) WRONG (nothing drawn)")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let card = view.resultCard
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)

            func ink(_ rect: NSRect) -> Int {
                var count = 0
                var x = rect.minX
                while x < rect.maxX {
                    var y = rect.minY
                    while y < rect.maxY {
                        // A bitmap is stored top-down; this view is not flipped.
                        let point = NSPoint(x: x * scale, y: (view.bounds.height - y) * scale)
                        if let colour = rep.colorAt(x: Int(point.x), y: Int(point.y))?
                            .usingColorSpace(.sRGB) {
                            let luminance = 0.2126 * colour.redComponent
                                + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
                            // 0.7 rather than 0.5: the original words are set at
                            // half ink on purpose (they are the reference, not
                            // the answer), and at 0.5 they came out as "no ink"
                            // — a check that cannot see the quieter of the two
                            // blocks is a check that would miss it going away.
                            if luminance < 0.7 { count += 1 }
                        }
                        y += 1
                    }
                    x += 1
                }
                return count
            }

            var trouble: [String] = []
            // The frame in view coordinates, for the two geometric questions.
            let frame = CGRect(x: region.minX - screen.frame.minX, y: region.minY - screen.frame.minY,
                               width: region.width, height: region.height)
            if card.isEmpty { trouble.append("no card") }
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            if !allowOutside, !card.contains(centre) { trouble.append("not over the frame") }
            if !NSRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height)
                .insetBy(dx: -1, dy: -1).contains(card) { trouble.append("off the screen") }
            if card.width < 339 || card.width > 561 { trouble.append("width \(Int(card.width))") }
            // Inside the card, so its own hairline edge is not counted as ink.
            if ink(card.insetBy(dx: 6, dy: 5)) < 40 { trouble.append("blank card") }
            if let extra, let complaint = extra(card, ink) { trouble.append(complaint) }
            parts.append("\(name) " + (trouble.isEmpty ? "ok"
                : "WRONG (" + trouble.joined(separator: ", ") + ")"))
        }

        for height in [40.0, 30.0, 24.0, 20.0, 14.0] {
            examine("\(Int(height))",
                    region: CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - height / 2,
                                   width: 320, height: height),
                    words: "Clothespeg 123")
        }
        // A word circled tightly: the frame is narrower than the card's own
        // minimum, which is the whole reason the width is not the frame's.
        examine("narrow", region: CGRect(x: screen.frame.midX - 30, y: screen.frame.midY - 30,
                                         width: 60, height: 60),
                words: "Clothespeg 123")
        // A paragraph in a one-line frame: this is the case that used to come out
        // as a single line ending in an ellipsis. The card has to be several
        // lines tall, which no amount of truncation can fake.
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 8)
        examine("long", region: CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - 10,
                                       width: 320, height: 20),
                words: paragraph) { card, _ in
            card.height > 100 ? nil : "cut to \(Int(card.height)) pt"
        }
        // Both languages on the card at once, each in its own half — that is what
        // 对照 means, and it is the one thing a card with one block cannot fake:
        // the words are set smaller and greyer above the line, the translation
        // larger and darker below it.
        examine("translation",
                region: CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - 15,
                               width: 320, height: 30),
                words: "The quick brown fox jumps over the lazy dog.",
                translated: "敏捷的棕色狐狸跳过了那只懒狗。") { card, ink in
            if card.height < 60 { return "only \(Int(card.height)) pt for two blocks" }
            let above = NSRect(x: card.minX, y: card.midY, width: card.width, height: card.height / 2)
            let below = NSRect(x: card.minX, y: card.minY, width: card.width, height: card.height / 2)
            if ink(above) < 20 { return "nothing above the line" }
            if ink(below) < 20 { return "nothing below the line" }
            return nil
        }
        // 2026-11-04: the answer sits where the words were read, and both
        // languages are still on it. A card that slipped back outside the frame,
        // or one that dropped the original on the way, fails here by name.
        examine("on frame",
                region: CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - 12,
                               width: 320, height: 24),
                words: "The quick brown fox jumps over the lazy dog.",
                translated: "敏捷的棕色狐狸跳过了那只懒狗。") { card, ink in
            let centre = NSPoint(x: screen.frame.width / 2,
                                 y: screen.frame.midY - screen.frame.minY)
            if !card.contains(centre) { return "answer is not where the words were" }
            if card.height < 60 { return "only \(Int(card.height)) pt for two blocks" }
            let above = NSRect(x: card.minX, y: card.midY, width: card.width, height: card.height / 2)
            let below = NSRect(x: card.minX, y: card.minY, width: card.width, height: card.height / 2)
            if ink(above) < 20 { return "nothing above the line" }
            if ink(below) < 20 { return "nothing below the line" }
            return nil
        }
        // A frame near the bottom of the screen: the card has to stay over it
        // even when the screen-edge clamp pulls at its y. This is the case that
        // would have gone above the frame under the old rule, and it is the one
        // that decides whether "on the frame" survives a clamp at all.
        examine("low frame", region: CGRect(x: screen.frame.midX - 160, y: screen.frame.minY + 30,
                                           width: 320, height: 30),
                words: "Clothespeg 123") { card, _ in
            card.contains(NSPoint(x: screen.frame.width / 2, y: 45)) ? nil : "slid off the low frame"
        }
        // A frame 680 wide and four fifths of the screen tall, which is what the
        // report of 2026-11-03 was: 560 points is too wide for either margin and
        // too tall for above or below, so the old rule glued the card to the
        // bottom of the display, across the frame's border, sharing the frame's
        // left edge — 「既不居中也不对齐」. The card has to look for a margin at
        // its narrower width instead. The assertions that decide are the
        // universal ones above ("not over the frame", "off the screen",
        // "width"); this case is what puts them under that strain.
        examine("big frame",
                region: CGRect(x: screen.frame.midX - 340,
                               y: screen.frame.minY + screen.frame.height * 0.1,
                               width: 680, height: screen.frame.height * 0.8),
                words: paragraph)
        // Centred on the frame rather than sharing its left edge. A frame wider
        // than the card is where the difference shows: one edge in line and a
        // lot of nothing beside it is the report this answers.
        examine("centred", region: CGRect(x: screen.frame.midX - 300, y: screen.frame.midY - 100,
                                          width: 600, height: 200),
                words: "Clothespeg 123") { card, _ in
            let off = card.midX - screen.frame.width / 2
            return abs(off) < 1.5 ? nil : "off centre by \(Int(off)) pt"
        }
        // The one frame allowed not to have its centre covered: one that is the
        // whole screen. Centring a card on it would put the answer in the middle
        // of everything, so it keeps the corner, 12 points in — not glued to
        // the bottom of the display while sharing the frame's left edge, which
        // was the one position that read as an accident.
        examine("whole screen", region: screen.frame.insetBy(dx: 2, dy: 2),
                words: "Clothespeg 123", allowOutside: true) { card, _ in
            if abs(card.minX - 14) > 1.5 { return "not tucked into the frame's corner" }
            if abs(card.minY - 14) > 1.5 { return "not tucked into the frame's corner" }
            return nil
        }

        // 2026-11-04: once the words are on the card the frame has no job left.
        // Geometry cannot see a bright rectangle brought back around a small
        // card, so this reads pixels. With a 900-point frame, a point well
        // inside it, one well outside, and the edge where the clay line used to
        // be must all be the same dimmed ground. Lifting the selection again
        // makes the first one white; drawing the frame again lights the edge.
        do {
            let view = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.appearance = NSAppearance(named: .aqua)
            let big = CGRect(x: screen.frame.midX - 450, y: screen.frame.midY - 300,
                             width: 900, height: 600)
            view.selectForTesting(big)
            view.showTranslationForTesting("敏捷的棕色狐狸跳过了那只懒狗。",
                                            from: "The quick brown fox jumps over the lazy dog.")
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                parts.append("flat ground WRONG (nothing drawn)")
                return "capture card: " + parts.joined(separator: ", ")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)

            func luminance(_ at: NSPoint) -> CGFloat? {
                let x = Int(at.x * scale)
                let y = Int((view.bounds.height - at.y) * scale)
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
                return 0.2126 * colour.redComponent
                    + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
            }

            // The card is at most 560 wide and centred, so 24 points inside a
            // 900-point frame is clear of it even on the frame's middle row.
            let left = big.minX - screen.frame.minX
            let row = big.midY - screen.frame.minY
            let inside = luminance(NSPoint(x: left + 24, y: row))
            let outside = luminance(NSPoint(x: max(4, left - 40), y: row))
            var edgeDelta: CGFloat = 0
            if let outside {
                for dx in stride(from: -4.0, through: 4.0, by: 1.0) {
                    if let value = luminance(NSPoint(x: left + dx, y: row)) {
                        edgeDelta = max(edgeDelta, abs(value - outside))
                    }
                }
            }
            if let inside, let outside {
                let even = abs(inside - outside) < 0.06 && edgeDelta < 0.12
                parts.append("flat ground " + (even ? "ok"
                    : String(format: "WRONG (inside %.2f, outside %.2f, edge Δ%.2f)",
                             inside, outside, edgeDelta)))
            } else {
                parts.append("flat ground WRONG (could not read the pixels)")
            }
        }
        return "capture card: " + parts.joined(separator: ", ")
    }

    /// The colour door: one chip, one bare key, one pixel, one value.
    ///
    /// The picture is two known halves rather than a fixture, so a y flip, a
    /// colour-space conversion, or a sample taken from the dimmed overlay
    /// instead of the frozen backdrop all come back as the wrong hex.
    @MainActor
    private static func colourLine() -> String {
        guard let screen = NSScreen.main, let twoTone = twoToneImage(for: screen) else {
            return "capture colour: no screen"
        }
        let box = NSRect(origin: .zero, size: screen.frame.size)
        var parts: [String] = []

        func fresh() -> CaptureSurface {
            let view = CaptureSurface(backdrop: twoTone, screen: screen, windows: [])
            view.frame = box
            view.appearance = NSAppearance(named: .aqua)
            return view
        }
        /// A whole repaint into a bitmap, and one luminance read out of it.
        /// Shared so the ring and rim checks ask the same question of the same
        /// pixels rather than each growing their own copy of the top-down flip.
        func pixels(_ view: CaptureSurface) -> NSBitmapImageRep? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return nil
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        func luminance(_ rep: NSBitmapImageRep, in view: CaptureSurface,
                       at point: NSPoint) -> CGFloat? {
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
            let x = Int(point.x * scale)
            let y = Int((view.bounds.height - point.y) * scale)
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent
                + 0.0722 * c.blueComponent
        }

        // 1. The key and the chip agree. A frame already on screen is dropped
        // rather than reinterpreted: this door has one order only.
        let armed = fresh()
        armed.selectForTesting(NSRect(x: 90, y: 90, width: 260, height: 160))
        guard let iKey = press(34, "i") else {
            return "capture colour: WRONG (no key event)"
        }
        armed.keyDown(with: iKey)
        let lit = armed.pickedChipsForTesting == ["colour"] && armed.colourAimingForTesting
        parts.append("I armed " + (lit ? "ok"
            : "WRONG (\(armed.pickedChipsForTesting), aiming \(armed.colourAimingForTesting))"))

        // 2. Geometry cannot see a bright rectangle come back, so read pixels.
        // 90,90 260×160 is the frame that was chosen before `I`.
        func flat(_ view: CaptureSurface, label: String) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                parts.append("\(label) WRONG (nothing drawn)")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
            func luminance(_ at: NSPoint) -> CGFloat? {
                let x = Int(at.x * scale)
                let y = Int((view.bounds.height - at.y) * scale)
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
                return 0.2126 * c.redComponent + 0.7152 * c.greenComponent
                    + 0.0722 * c.blueComponent
            }
            let inside = luminance(NSPoint(x: 110, y: 170))
            let outside = luminance(NSPoint(x: 400, y: 170))
            let edge = luminance(NSPoint(x: 90, y: 170))
            if let inside, let outside, let edge {
                let even = abs(inside - outside) < 0.08 && abs(edge - outside) < 0.12
                parts.append("\(label) " + (even ? "ok"
                    : String(format: "WRONG (inside %.2f, outside %.2f, edge %.2f)",
                             inside, outside, edge)))
            } else {
                parts.append("\(label) WRONG (could not read the pixels)")
            }
        }
        flat(armed, label: "aiming flat")

        // 3. Two known pixels, one in each half: the y direction has to be
        // right, and the value has to be the frozen backdrop's, not the dim.
        let upper = NSPoint(x: 320, y: screen.frame.height - 120)
        let lower = NSPoint(x: 320, y: 120)
        let wantedUpper = ColourSampler.colour(at: upper, in: twoTone).map(ColourSampler.hex)
        let wantedLower = ColourSampler.colour(at: lower, in: twoTone).map(ColourSampler.hex)
        let result = fresh()
        result.aimColourForTesting(upper)
        result.takeColourForTesting(upper)
        let gotUpper = result.colourHexForTesting
        let second = fresh()
        second.aimColourForTesting(lower)
        second.takeColourForTesting(lower)
        let gotLower = second.colourHexForTesting
        let exact = gotUpper == wantedUpper && gotLower == wantedLower
            && wantedUpper == "#0000FF" && wantedLower == "#FF0000"
        parts.append("sample \(gotUpper ?? "nil")/\(gotLower ?? "nil") "
            + (exact ? "ok" : "WRONG (wanted #0000FF/#FF0000)"))

        // 3b. A moved loupe repaints the whole screen. The ring that first
        // forced this now lives on the result card, but a partial repaint is
        // still the wrong answer for a state that dims the entire screen, and
        // two small rectangles is exactly the shape the trail bug had.
        let moved = fresh()
        moved.aimColourForTesting(upper)
        moved.moveColourForTesting(lower)
        let dirty = moved.dirtyForTesting
        let whole = dirty.count == 1 && dirty[0].contains(box)
        parts.append("whole repaint " + (whole ? "ok"
            : "WRONG (dirty \(dirty.map { "\(Int($0.width))×\(Int($0.height))" }))"))

        // 3c. The disc that was too big on a real screen. A ceiling rather
        // than an exact copy of the number, so a smaller design still passes.
        let disc = 2 * ColourLoupe.radius
        parts.append("loupe \(Int(disc))pt " + (disc <= 104 ? "ok"
            : "WRONG (wanted at most 104)"))

        // 4. The card is on screen, and the ground under it is still flat.
        flat(result, label: "result flat")
        if let card = result.colourCardForTesting {
            let onScreen = box.insetBy(dx: 8, dy: 8).contains(card)
            // The 168 × 56 first pass read as a panel rather than a value.
            let small = card.width <= 140 && card.height <= 48
            parts.append("card " + (onScreen && small ? "ok"
                : "WRONG (on screen \(onScreen), \(Int(card.width))×\(Int(card.height)))"))
        } else {
            parts.append("card WRONG (never drawn)")
        }

        // 5. The check hands over the value and nothing else. A colour that
        // reached `onFinish` would have photographed the screen instead.
        var taken: [String] = []
        var pictures = 0
        result.onFinishColour = { taken.append($0) }
        result.onFinish = { _ in pictures += 1 }
        result.finishColourForTesting()
        let handed = taken == [gotUpper ?? ""] && pictures == 0
        parts.append("check " + (handed ? "ok"
            : "WRONG (took \(taken), pictures \(pictures))"))

        // 6. Return agrees with the check; while aiming it takes nothing.
        let byKey = fresh()
        byKey.aimColourForTesting(upper)
        byKey.takeColourForTesting(upper)
        var fromKey: [String] = []
        var keyPictures = 0
        byKey.onFinishColour = { fromKey.append($0) }
        byKey.onFinish = { _ in keyPictures += 1 }
        guard let enter = press(36, "\r") else {
            return "capture colour: WRONG (no Return event)"
        }
        byKey.keyDown(with: enter)
        let aiming = fresh()
        aiming.aimColourForTesting(upper)
        var aimingTook: [String] = []
        var aimingPictures = 0
        aiming.onFinishColour = { aimingTook.append($0) }
        aiming.onFinish = { _ in aimingPictures += 1 }
        aiming.keyDown(with: enter)
        let keys = fromKey == [gotUpper ?? ""] && keyPictures == 0
            && aimingTook.isEmpty && aimingPictures == 0
        parts.append("return " + (keys ? "ok"
            : "WRONG (result \(fromKey)/\(keyPictures), aiming \(aimingTook)/\(aimingPictures))"))

        // 7. The value that leaves really is on a pasteboard carrying this
        // app's own-write mark, or the watcher hangs a second card of it.
        let pb = NSPasteboard(name: NSPasteboard.Name("app.clothespeg.colourSelftest"))
        CaptureController.put(gotUpper ?? "", on: pb)
        let readBack = pb.string(forType: .string)
        let marked = pb.string(forType: ClipboardWatcher.ourWrite) == "1"
        parts.append("pasteboard " + (readBack == gotUpper && marked ? "ok"
            : "WRONG (read \(readBack ?? "nil"), marked \(marked))"))

        // 8. The white dot is not a second cursor. While aiming the pointer
        // sits on plain dimmed pixels; after the click the ring is there on
        // the card's tether. Reading the same two points in both states is
        // what makes "gone" and "back" one check instead of two guesses.
        let aimed = fresh()
        aimed.aimColourForTesting(upper)
        let ringPoint = NSPoint(x: upper.x + 5, y: upper.y)
        let groundPoint = NSPoint(x: upper.x + 12, y: upper.y)
        if let aimRep = pixels(aimed), let resultRep = pixels(result),
           let aimRing = luminance(aimRep, in: aimed, at: ringPoint),
           let aimGround = luminance(aimRep, in: aimed, at: groundPoint),
           let resultRing = luminance(resultRep, in: result, at: ringPoint),
           let resultGround = luminance(resultRep, in: result, at: groundPoint) {
            let quiet = abs(aimRing - aimGround) < 0.12
            let shown = resultRing - resultGround > 0.3
            parts.append("rings " + (quiet && shown ? "ok"
                : String(format: "WRONG (aim %.2f/%.2f, result %.2f/%.2f)",
                         aimRing, aimGround, resultRing, resultGround)))
        } else {
            parts.append("rings WRONG (could not read the pixels)")
        }

        // 9. A near-white swatch on the near-white card: only the rim can
        // separate them. This is the `#F8F8F8` screenshot that asked for a
        // border, read as pixels against the panel a few points to its left.
        guard let paleImage = nearWhiteImage(for: screen) else {
            parts.append("border WRONG (no near-white picture)")
            return "capture colour: " + parts.joined(separator: ", ")
        }
        let pale = CaptureSurface(backdrop: paleImage, screen: screen, windows: [])
        pale.frame = box
        pale.appearance = NSAppearance(named: .aqua)
        let palePoint = NSPoint(x: 420, y: screen.frame.height - 200)
        pale.aimColourForTesting(palePoint)
        pale.takeColourForTesting(palePoint)
        if let rep = pixels(pale), let swatch = pale.colourSwatchForTesting,
           let card = pale.colourCardForTesting,
           let rim = luminance(rep, in: pale,
                               at: NSPoint(x: swatch.minX, y: swatch.midY)),
           let panel = luminance(rep, in: pale,
                                 at: NSPoint(x: card.minX + 4, y: card.midY)) {
            parts.append("border " + (panel - rim > 0.2 ? "ok"
                : String(format: "WRONG (panel %.2f, rim %.2f)", panel, rim)))
        } else {
            parts.append("border WRONG (could not read the pixels)")
        }

        // 10. The collapsed bar is not empty: one sentence on the line and
        // the value in the middle, the same two slots a reading fills. Reading
        // them through `bar()` means the check covers what is actually drawn.
        let barView = fresh()
        barView.aimColourForTesting(upper)
        barView.takeColourForTesting(upper)
        let said = barView.lineForTesting
        let value = barView.middleForTesting
        let filled = !said.isEmpty && value == (gotUpper ?? "")
        parts.append("bar " + (filled ? "ok"
            : "WRONG (line [\(said)], middle [\(value)])"))

        return "capture colour: " + parts.joined(separator: ", ")
    }

    /// A synthetic desktop for a photograph of the colour door: flat panels
    /// of known colour at backing scale, so the loupe has an exact hex to
    /// read and the picture does not depend on what the live screen was doing.
    private static func previewPicture(for screen: NSScreen) -> CGImage? {
        let unit: CGFloat = 2
        let w = Int((screen.frame.width * unit).rounded())
        let h = Int((screen.frame.height * unit).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        func fill(_ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
            ctx.fill(rect)
        }
        fill(CGRect(x: 0, y: 0, width: w, height: h), 0.96, 0.96, 0.95)
        fill(CGRect(x: 120 * unit, y: 300 * unit,
                    width: 640 * unit, height: 420 * unit), 0.16, 0.36, 0.55)
        fill(CGRect(x: 800 * unit, y: 300 * unit,
                    width: 420 * unit, height: 420 * unit), 0.85, 0.32, 0.26)
        fill(CGRect(x: 1240 * unit, y: 300 * unit,
                    width: 300 * unit, height: 420 * unit), 0.24, 0.48, 0.33)
        fill(CGRect(x: 120 * unit, y: 120 * unit,
                    width: 1420 * unit, height: 140 * unit), 0.99, 0.99, 0.98)
        return ctx.makeImage()
    }

    /// A screen-sized picture whose top half is pure blue and bottom half pure
    /// red, one pixel per point so the view-to-backdrop arithmetic is 1:1.
    private static func twoToneImage(for screen: NSScreen) -> CGImage? {
        let w = Int(screen.frame.width.rounded())
        let h = Int(screen.frame.height.rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        return ctx.makeImage()
    }

    /// The picture that asked for a border: a near-white window background
    /// (`#F8F8F8`) behind a white result card, where a white-only swatch rim
    /// disappears and the colour cannot be told from the surface it sits on.
    private static func nearWhiteImage(for screen: NSScreen) -> CGImage? {
        let w = Int(screen.frame.width.rounded())
        let h = Int(screen.frame.height.rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let value: CGFloat = 248.0 / 255.0
        ctx.setFillColor(red: value, green: value, blue: value, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// A picture with known words on it, for the reader to read.    ///
    /// Drawn rather than loaded from a fixture: a fixture would be one more file
    /// to keep beside the app, and what this has to prove is that the reader
    /// works on this machine — not that a particular PNG is still where it was.
    private static func sampleWords() -> CGImage? {
        let width = 520
        let height = 120
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        ("Clothespeg 123" as NSString).draw(
            at: NSPoint(x: 26, y: 38),
            withAttributes: [.font: NSFont.systemFont(ofSize: 46, weight: .medium),
                             .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// A place to stand for a surface that only needs its geometry measured.
    /// A synthetic click at a point in a surface's own coordinates.
    ///
    /// The one gesture no seam can stand in for: whether a restored frame is
    /// accepted by the same code that accepts a drawn one is a question about
    /// `mouseDown`, and answering it any other way would be testing the answer
    /// rather than the thing. `windowNumber: 0` because the harness's surface is
    /// not in a window; the view is at the origin, so a point in it is a point
    /// in the event. `count: 2` is the same event with the click count a
    /// double-click carries — the app tells the two apart by nothing else.
    private static func click(at local: NSPoint, count: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDown,
                           location: local,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: count,
                           pressure: 1)
    }

    /// A synthetic key press, by key code rather than by character.
    ///
    /// `keyDown` switches on the code — 49 is Space, 36 is Return — and the
    /// characters are carried along only because the initialiser insists on
    /// them.
    private static func press(_ code: UInt16, _ characters: String) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false,
                         keyCode: code)
    }

    private static func blankImage() -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()
    }

    private static func isAdvanced(_ step: LongStitcher.Step, _ pixels: Int) -> Bool {
        if case .advanced(let moved) = step { return moved == pixels }
        return false
    }

    private static func isStill(_ step: LongStitcher.Step) -> Bool {
        if case .still = step { return true }
        return false
    }

    private static func isLost(_ step: LongStitcher.Step) -> Bool {
        if case .lost = step { return true }
        return false
    }

    /// A page-shaped sheet: rows of bars of varying length on white, which is
    /// the kind of picture registration is good at and the kind a long capture
    /// is usually pointed at. Deterministic, so two runs are comparable.
    private static func syntheticPage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func roll() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Double(seed % 1000) / 1000
        }
        var y = 0
        while y < height {
            let barHeight = 6 + Int(roll() * 10)
            let x = 10 + Int(roll() * 40)
            let length = min(80 + Int(roll() * 200), width - x - 10)
            context.setFillColor(red: 0.1 + roll() * 0.3, green: 0.1,
                                 blue: 0.1 + roll() * 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: max(length, 1), height: barHeight))
            y += barHeight + 4 + Int(roll() * 14)
        }
        return context.makeImage()!
    }

    /// Whether the keys that end a capture can still be taken for the length of
    /// one.
    ///
    /// Worth asking because the answer is not a property of this code: a bare
    /// Escape or Return is a key any other app may already hold, and a refusal
    /// would show up as nothing more than "Esc does nothing" in the middle of a
    /// capture — which is the exact bug that made the long capture need these
    /// keys in the first place. Each registration is dropped immediately; the
    /// point is the status, not the shortcut.
    private static func keysLine() -> String {
        let wanted: [(name: String, code: Int, id: UInt32)] = [
            ("esc", kVK_Escape, 300),
            ("return", kVK_Return, 301),
            ("keypad enter", kVK_ANSI_KeypadEnter, 302),
        ]
        let said = wanted.map { wanted -> String in
            let key = HotKey(keyCode: wanted.code, modifiers: 0, id: wanted.id) {}
            let state = key.registerStatus == noErr ? "ok" : "REFUSED (\(key.registerStatus))"
            return "\(wanted.name) \(state)"
        }
        return "capture keys: " + said.joined(separator: ", ")
    }

    /// Holds what the detached task found. A class rather than captured
    /// variables because the task writes from another thread and the reading
    /// happens after `wait`, which is the one place a plain `var` would compile
    /// and still be a race.
    private final class Box: @unchecked Sendable {
        var grab = "capture grab: did not run"
        var compare = "capture compare: did not run"
    }

    private final class ImageBox: @unchecked Sendable {
        var image: CGImage?
    }

    /// Draws the overlay to a PNG without showing it.
    ///
    /// The overlay is the one part of the capture that cannot be checked from
    /// the outside: it lives for a second, it covers the screen while it is
    /// there, and a screenshot of it would need the very permission it is
    /// testing. Rendering the same view off screen answers the questions that
    /// matter — is the dimming right, is the highlight where the window is, is
    /// the badge legible, is the type the right way up — before anyone has to
    /// press anything.
    ///
    /// `hovered` lights a window-sized rectangle, `selected` a dragged one.
    /// Both are nil in ordinary use; see `CaptureSurface.previewHighlight`.
    /// `aspect` locks the shape the way `R` does, and reshapes the preview
    /// rectangle with it — a picture of a "16:9" frame that is not 16:9 would be
    /// a picture of the one thing this harness exists to check.
    @MainActor
    static func render(to path: String, hovered: Bool, selected: Bool,
                       aspect: CropAspect = .free, panel: String? = nil,
                       long: Int? = nil, read: String? = nil, note: String? = nil,
                       translated: String? = nil, armed: String? = nil,
                       appearance: String? = nil, colour: NSPoint? = nil,
                       colourTaken: Bool = false, synthetic: Bool = false,
                       pale: Bool = false, reveal: TimeInterval? = nil,
                       inPlace: Bool = false) -> String {
        guard let screen = NSScreen.main else { return "capture preview: no screen" }
        let image: CGImage
        if synthetic {
            // `_PALE` is the near-white desktop that made the swatch vanish
            // into the card; the ordinary synthetic picture is three dark
            // panels, which would show a border for the wrong reason.
            let made = pale ? nearWhiteImage(for: screen) : previewPicture(for: screen)
            guard let made = made else {
                return "capture preview: the synthetic picture failed"
            }
            image = made
        } else {
            guard ScreenGrab.hasAccess else {
                return "capture preview: NOT GRANTED, nothing to draw"
            }
            let box = ImageBox()
            let group = DispatchGroup()
            group.enter()
            Task.detached {
                box.image = try? await ScreenGrab.screenImage(of: screen)
                group.leave()
            }
            _ = group.wait(timeout: .now() + 20)
            guard let grabbed = box.image else { return "capture preview: the grab failed" }
            image = grabbed
        }

        let view = CaptureSurface(backdrop: image, screen: screen, windows: [])
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        // Which way the bar dresses, for a photograph of it in the appearance
        // somebody is asking about rather than the one this app happens to be
        // wearing while the harness runs.
        if let appearance {
            view.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        view.aspect = aspect
        // Which menu, not merely whether one: there are two now, and a
        // photograph of "a panel" would be a photograph of whichever one the
        // code happened to open.
        if let panel { _ = view.openPanelForTesting(panel) }
        view.previewLong = long
        // The armed state is a 15% clay wash, and a wash is a thing to look at:
        // the harness can assert which chips are picked, but not whether the
        // picked one still reads as a button.
        view.armForTesting(armed)
        // The two states are two doors now, and a photograph has to show the
        // one that was asked for: a translation shown as a bare reading would
        // be a picture of a card this app no longer makes.
        if let translated {
            view.showTranslationForTesting(translated, from: read)
        } else {
            view.showReadingForTesting(read)
        }
        view.previewNote = note
        // A render has no pointer to move, so the loupe is put on the point
        // directly. `_TAKEN` answers the click as well, for the card and check.
        if let colour {
            view.aimColourForTesting(colour)
            if colourTaken { view.takeColourForTesting(colour) }
        }
        if selected {
            // Drawn through the same arithmetic the hand goes through, rather
            // than by setting a rectangle directly: a harness that builds its
            // own rectangle is a harness that can show a shape the app would
            // never produce — which is exactly what a 9:16 preview did, tall
            // enough to leave the screen and take the size badge with it.
            let start = NSPoint(x: screen.frame.midX - screen.frame.width * 0.275,
                                y: screen.frame.midY - screen.frame.height * 0.175)
            let end = NSPoint(x: start.x + screen.frame.width * 0.55,
                              y: start.y + screen.frame.height * 0.35)
            view.previewSelection = CaptureSurface.rectangle(from: start, to: end,
                                                            aspect: aspect, within: screen.frame)
        } else if hovered {
            view.previewHighlight = CGRect(x: screen.frame.minX + 120,
                                           y: screen.frame.minY + 200,
                                           width: (screen.frame.width * 0.62).rounded(),
                                           height: (screen.frame.height * 0.52).rounded())
        }
        // A short, one-line-tall selection, to exercise the reading sheet's
        // "too short for a line" path that used to paint a blank panel.
        //
        // The size is a knob rather than a constant because the question is not
        // "does 30 points work" but "how short does the frame have to be before
        // the words stop showing" — and the answer for a frame around one line
        // of small type is 15–20, not 30. `=1` keeps the old 30×320.
        if let short = ProcessInfo.processInfo.environment["CLOTHESPEG_CAPTURE_SHORT"],
           let sel = view.previewSelection {
            let env = ProcessInfo.processInfo.environment
            let height = Double(env["CLOTHESPEG_CAPTURE_SHORT_H"] ?? "") ?? (short == "1" ? 30 : (Double(short) ?? 30))
            let width = Double(env["CLOTHESPEG_CAPTURE_SHORT_W"] ?? "") ?? 320
            view.previewSelection = CGRect(x: sel.minX, y: sel.midY - height / 2,
                                           width: min(sel.width, width), height: height)
        }

        // A still of the answer part-way through arriving. The reveal only
        // starts when the view has a window, so an off-screen host is the
        // smallest thing that makes a preview show what the real screen shows.
        // One warm-up draw sets the clock; the picture below is taken later.
        //
        // The in-place answer needs the same host, and for the same reason: its
        // clock starts in `showInPlaceTranslation`, which leaves a windowless
        // view alone. So the host comes first, the stand-in answer second, and
        // the photograph last.
        var host: NSWindow?
        if reveal != nil || inPlace {
            let made = NSWindow(contentRect: view.bounds, styleMask: .borderless,
                                backing: .buffered, defer: false)
            made.contentView = view
            host = made
        }

        // The in-place picture, made here rather than translated: three blocks
        // over the frame that is already chosen, so a still can catch them
        // arriving one at a time without a network, a key or an engine.
        if inPlace, let chosen = view.previewSelection,
           let crop = image.cropping(to: CGRect(x: (chosen.minX - screen.frame.minX)
                                                * (CGFloat(image.width) / screen.frame.width),
                                                y: (screen.frame.maxY - chosen.maxY)
                                                * (CGFloat(image.height) / screen.frame.height),
                                                width: chosen.width
                                                * (CGFloat(image.width) / screen.frame.width),
                                                height: chosen.height
                                                * (CGFloat(image.height) / screen.frame.height))) {
            let boxes = [CGRect(x: 0.06, y: 0.66, width: 0.36, height: 0.14),
                         CGRect(x: 0.06, y: 0.40, width: 0.60, height: 0.14),
                         CGRect(x: 0.06, y: 0.14, width: 0.48, height: 0.14)]
            let blocks = boxes.map { TextBlock(text: "一", box: $0, lineCount: 1) }
            let words = ["第一块已经译好", "第二块正在进来", "第三块还在原文里"]
            if let rendered = TranslatedImage.render(base: crop, blocks: blocks,
                                                     translations: words) {
                view.showReadingForTesting("one two three")
                view.showInPlaceTranslation(rendered, words: words.joined(separator: "\n"),
                                            base: crop, boxes: boxes)
            }
        }

        if let reveal {
            if let warm = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: warm)
            }
            Thread.sleep(forTimeInterval: max(0, reveal))
        }
        withExtendedLifetime(host) {}

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "capture preview: no bitmap"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return "capture preview: no png"
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return "capture preview: could not write \(path) — \(error.localizedDescription)"
        }
        return "capture preview: \(rep.pixelsWide)×\(rep.pixelsHigh) → \(path)"
    }

    /// How far apart two pictures are, as a fraction of full scale.
    ///
    /// Both are reduced to a 16×16 grid first: this is a question about which
    /// part of the screen was photographed, and a per-pixel comparison would
    /// answer a much narrower question while taking a long time to do it. Zero
    /// is identical, one is black against white.
    private static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard let left = signature(a), let right = signature(b),
              left.count == right.count, !left.isEmpty else { return nil }
        var total = 0.0
        for i in 0..<left.count {
            total += abs(Double(left[i]) - Double(right[i]))
        }
        return total / Double(left.count) / 255.0
    }

    private static func signature(_ image: CGImage, side: Int = 16) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress,
                                          width: side, height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }

    /// The two decisions made before a request ever leaves: whether a pasted
    /// base URL is completed, and whether the model gets one message or two.
    /// Both are pure functions, so either can be wrong without a failing
    /// request ever showing up — a 404 with no detail, or a 400 about roles.
    static func translationAPILine() -> String {
        let base = "https://example.com/compatible-mode/v1"
        let full = base + "/chat/completions"
        let completed = TranslationAPI.resolvedEndpoint(base) == full
        let kept = TranslationAPI.resolvedEndpoint(full) == full
        let slash = TranslationAPI.resolvedEndpoint(base + "/") == full
        let other = "https://example.com/api/v1/translate"
        let leftAlone = TranslationAPI.resolvedEndpoint(other) == other
        let chat = TranslationAPI.messages(system: "R", text: "T", model: "qwen-plus")
        let flat = TranslationAPI.messages(system: "R", text: "T", model: "qwen-mt-plus")
        let two = chat.count == 2 && chat[0]["role"] == "system"
            && chat[1]["role"] == "user" && chat[1]["content"] == "T"
        let one = flat.count == 1 && flat[0]["role"] == "user"
            && flat[0]["content"] == "R\n\nT"
        let named = TranslationAPI.usesSingleMessage("qwen-mt-plus")
            && !TranslationAPI.usesSingleMessage("qwen-plus")
        let ok = completed && kept && slash && leftAlone && two && one && named
        return "translate api: "
            + (ok ? "base ok, full ok, slash ok, other ok, two messages ok, one message ok, names ok"
                  : "WRONG (base \(completed), full \(kept), slash \(slash), other \(leftAlone), "
                    + "two \(two), one \(one), names \(named))")
    }
}
