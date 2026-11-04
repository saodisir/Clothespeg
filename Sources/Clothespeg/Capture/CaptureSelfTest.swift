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
        lines.append(languageLine())
        lines.append(MainActor.assumeIsolated { againLine() })
        lines.append(MainActor.assumeIsolated { chooseLine() })
        lines.append(MainActor.assumeIsolated { chipsLine() })
        lines.append(MainActor.assumeIsolated { languagesLine() })
        lines.append(MainActor.assumeIsolated { styleLine() })
        lines.append(MainActor.assumeIsolated { cardLine() })
        lines.append(keysLine())
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
            return "capture done: MISSING (a growing bar should carry a Done pill)"
        }
        let inside = short.capsule.contains(short.done)
        let onScreen = screen.frame.contains(short.capsule)
        let sized = short.done.height == 26 && short.done.width >= 44
        var parts: [String] = []
        parts.append("pill \(Int(short.done.width))×\(Int(short.done.height)) "
            + (inside && onScreen && sized ? "ok"
               : "WRONG (inside \(inside), on screen \(onScreen), sized \(sized))"))

        // The way out, beside the way on. Inside the capsule, clear of the pill,
        // round, and smaller than it — a ✕ the size of the pill would be a second
        // button claiming equal standing, and the exit is not that.
        let exitInside = short.capsule.contains(short.close)
        let clear = !short.close.intersects(short.done)
        let exitSized = short.close.width == short.close.height && short.close.width <= 24
        parts.append("✕ \(Int(short.close.width))×\(Int(short.close.height)) "
            + (exitInside && clear && exitSized ? "ok"
               : "WRONG (inside \(exitInside), clear of the pill \(clear), sized \(exitSized))"))

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

        // The chain a report of "点击翻译无效，还显示在翻译中" broke: the door is
        // chosen, the area is drawn, the words come back, and the engine is
        // asked by itself — no second press, and nothing depending on a reading
        // that has already been answered.
        let area = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100,
                          width: 400, height: 200)
        func translateDoor() -> CaptureSurface {
            let surface = CaptureSurface(backdrop: blank, screen: screen, windows: [])
            surface.frame = NSRect(origin: .zero, size: screen.frame.size)
            surface.selectForTesting(area)
            _ = surface.takeBarClickForTesting(
                at: NSPoint(x: shot.language.midX - screen.frame.minX,
                            y: shot.language.midY - screen.frame.minY))
            surface.showReading("one\ntwo")
            return surface
        }

        var asked: String?
        var handedOver: String?
        let door = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        door.frame = NSRect(origin: .zero, size: screen.frame.size)
        door.onTranslate = { asked = $0 }
        door.onFinishTranslation = { handedOver = $0 }
        door.selectForTesting(area)
        let chosen = door.takeBarClickForTesting(
            at: NSPoint(x: shot.language.midX - screen.frame.minX,
                        y: shot.language.midY - screen.frame.minY))
        door.showReading("one\ntwo")
        parts.append("asks by itself " + (chosen && asked == "one\ntwo" ? "ok"
            : "WRONG (chose \(chosen), asked \(asked ?? "nothing"))"))

        // And the pill hands the translation over — the only useful way out of
        // this door, and the reason it says 复制 rather than 确认.
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
        return "capture text: " + parts.joined(separator: ", ")
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
        _ = door.takeBarClickForTesting(
            at: NSPoint(x: bar.language.midX - screen.frame.minX,
                        y: bar.language.midY - screen.frame.minY))
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
        // 译 is not in this list any more: it carries a value now, so it is the
        // second member of the values group and is checked with 比例 below.
        var chips = [bar.long, bar.read]
        if !bar.again.isEmpty { chips.append(bar.again) }
        chips.append(bar.edit)
        let boxes = chips.allSatisfy { $0.width == 30 && $0.height == 26 }
        let sizes = chips.map { "\(Int($0.width))×\(Int($0.height))" }.joined(separator: " ")
        parts.append("\(chips.count) 30×26 " + (boxes ? "ok" : "WRONG (\(sizes))"))

        // Asked as distances between edges rather than as a count: a chip that
        // grew by a point would move its neighbours and still pass a count.
        //
        // The two numbers that are not four are the group seam in front of 长图
        // and the tight gap inside the values group. Two groups that were spaced
        // like one would be two groups nobody can see.
        var gaps: [Int] = [Int(bar.language.minX - bar.ratio.maxX),
                           Int(bar.long.minX - bar.language.maxX)]
        for (left, right) in zip(chips, chips.dropFirst()) {
            gaps.append(Int(right.minX - left.maxX))
        }
        let wantedGaps = ([4, 10] + Array(repeating: 4, count: chips.count - 1))
            .map(String.init).joined(separator: "/")
        parts.append("gap \(gaps.map(String.init).joined(separator: "/")) "
            + (gaps == ([4, 10] + Array(repeating: 4, count: chips.count - 1))
               ? "ok" : "WRONG (wanted \(wantedGaps))"))

        // The two value chips: wider than a chip, the same height, and together
        // at the start of the row — the ratio one first, then the language one.
        let ratioWide = bar.ratio.width > 30 && bar.ratio.height == 26
        let languageWide = bar.language.width > 30 && bar.language.height == 26
        let valuesAtStart = bar.ratio.maxX <= bar.language.minX
            && bar.language.maxX <= bar.long.minX
        parts.append("values \(Int(bar.ratio.width))+\(Int(bar.language.width))×26 "
            + (ratioWide && languageWide && valuesAtStart ? "ok"
               : "WRONG (wide \(ratioWide)/\(languageWide), together \(valuesAtStart))"))

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
        // `R` filled the ratio chip and `L`/`W`/`T` filled nothing, so three
        // keys looked like they had not been heard. Pressed with nothing chosen,
        // which is the state those keys exist for — with a frame already drawn
        // they act on it at once and there is no arming to see.
        var armed: [String] = []
        let wanted: [(UInt16, String)] = [(37, "long"), (13, "read"), (17, "translate")]
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
        // The harness runs on a real Mac with real preferences, so it puts back
        // what it found. A self-test that quietly widened somebody's shortlist
        // would be a self-test that changed the app.
        let savedList = TranslationTargets.chosen
        let savedCurrent = TranslationTargets.current
        defer {
            TranslationTargets.chosen = savedList
            TranslationTargets.current = savedCurrent
        }

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

        // The chevron opens the menu and the body does not. Two halves of one
        // box, and geometry alone cannot say which answers what.
        guard let byClick = surface() else { return "capture languages: MISSING (no bar to press)" }
        let bar = byClick.shotBarOnScreen!
        _ = byClick.takeBarClickForTesting(
            at: NSPoint(x: bar.languageMenu.midX - screen.frame.minX,
                        y: bar.languageMenu.midY - screen.frame.minY))
        let opened = byClick.languageRowsOnScreen.count
        // Pressed with no area drawn, which is the state where arming is
        // visible at all: with a frame already there the press translates at
        // once and there is no chip to light — that half is `capture text`'s
        // "asks by itself".
        let byBody = CaptureSurface(backdrop: blank, screen: screen, windows: [])
        byBody.frame = NSRect(origin: .zero, size: screen.frame.size)
        _ = byBody.takeBarClickForTesting(
            at: NSPoint(x: bar.language.minX + 12 - screen.frame.minX,
                        y: bar.language.midY - screen.frame.minY))
        let armedByBody = byBody.pickedChipsForTesting
        parts.append("chevron opens · body translates "
            + (opened == 3 && armedByBody == ["translate"] ? "ok"
               : "WRONG (menu rows \(opened), body armed \(armedByBody))"))

        // One panel at a time. Opening the shapes menu has to close this one by
        // construction rather than by anybody remembering to.
        _ = byClick.openPanelForTesting("ratio")
        let languageStillOpen = !byClick.languageRowsOnScreen.isEmpty
        parts.append("one panel " + (languageStillOpen
            ? "WRONG (the language menu survived the shapes menu)" : "ok"))

        // And the setting is a setting: written, read back, and never empty.
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
    /// - it does not sit on the frame it belongs to (the frame is what the words
    ///   are being checked against),
    /// - it is inside the screen,
    /// - its width is the card's own 340–560 rather than the frame's,
    /// - it has ink in it — counted, not assumed.
    ///
    /// 14, 20 and 24 are the heights a frame round one line of small type comes
    /// to; 40 is a comfortable line; 60×60 is a word circled tightly; and the
    /// long paragraph is the case that used to be one line and an ellipsis.
    @MainActor
    private static func cardLine() -> String {
        guard let screen = NSScreen.main, let blank = blankImage() else {
            return "capture card: no screen"
        }
        var parts: [String] = []

        func examine(_ name: String, region: CGRect, words: String?, translated: String? = nil,
                     overlapping: Bool = false,
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
            if card.intersects(frame), !overlapping { trouble.append("on top of the frame") }
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
        // A frame near the bottom of the screen: there is no room below it, so
        // the card has to go above. The rule is "never on the frame", not "always
        // below it", and the second one is what the first version would have
        // done while looking perfectly correct in the middle of the screen.
        examine("low frame", region: CGRect(x: screen.frame.midX - 160, y: screen.frame.minY + 30,
                                           width: 320, height: 30),
                words: "Clothespeg 123") { card, _ in
            card.minY >= screen.frame.minY + 30 + 29 ? nil : "still below the frame"
        }
        // A frame 680 wide and four fifths of the screen tall, which is what the
        // report of 2026-11-03 was: 560 points is too wide for either margin and
        // too tall for above or below, so the old rule glued the card to the
        // bottom of the display, across the frame's border, sharing the frame's
        // left edge — 「既不居中也不对齐」. The card has to look for a margin at
        // its narrower width instead. The assertions that decide are the
        // universal ones above ("on top of the frame", "off the screen",
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
        // The one case that has to cover the frame: a frame that is the whole
        // screen. It goes into the frame's own corner, 12 points in — not glued
        // to the bottom of the display while sharing the frame's left edge,
        // which was the one position that read as an accident.
        examine("whole screen", region: screen.frame.insetBy(dx: 2, dy: 2),
                words: "Clothespeg 123", overlapping: true) { card, _ in
            if abs(card.minX - 14) > 1.5 { return "not tucked into the frame's corner" }
            if abs(card.minY - 14) > 1.5 { return "not tucked into the frame's corner" }
            return nil
        }
        return "capture card: " + parts.joined(separator: ", ")
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
                       appearance: String? = nil) -> String {
        guard ScreenGrab.hasAccess else { return "capture preview: NOT GRANTED, nothing to draw" }
        guard let screen = NSScreen.main else { return "capture preview: no screen" }

        let box = ImageBox()
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            box.image = try? await ScreenGrab.screenImage(of: screen)
            group.leave()
        }
        _ = group.wait(timeout: .now() + 20)
        guard let image = box.image else { return "capture preview: the grab failed" }

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
        // one that was asked for: a translation with 确认 on the pill would be a
        // picture of a card this app no longer makes.
        if let translated {
            view.showTranslationForTesting(translated, from: read)
        } else {
            view.showReadingForTesting(read)
        }
        view.previewNote = note
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
}
