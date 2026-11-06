import AppKit
import SwiftUI

/// Renders the editor window offscreen, so a layout change can be looked at
/// without a screen.
///
/// `cacheDisplay(in:to:)` draws the real view hierarchy into a bitmap: what
/// comes out is what the window would show, which is why this is the only way
/// to check chrome that nobody is currently looking at. It is used by the build
/// hook in `main.swift` (environment variable `CLOTHESPEG_EDITOR_PREVIEW`), and
/// by nothing in the app itself.
@MainActor
enum EditorPreview {
    /// Renders the settings window offscreen.
    ///
    /// The one page in the app that is SwiftUI, and therefore the one page
    /// nothing else here can look at. What it exists for is the failure that has
    /// no symptom: a row added to a page pushes the last one below the bottom
    /// edge, and what the user loses is a setting they no longer scroll far
    /// enough to find. Only a picture catches that.
    ///
    /// No number is printed, and that is deliberate: `fittingSize` on an
    /// `NSHostingView` that has already been given a frame reports that frame,
    /// so every page "asks for" the same height and the line reads as a check
    /// while measuring nothing. A number that cannot differ is worse than no
    /// number, because it looks like evidence.
    static func renderSettings(to path: String, page: String?) {
        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_DARK"] != nil {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        let chosen = page.flatMap(SettingsView.Section.init(rawValue:)) ?? .general
        let size = SettingsWindow.size
        let host = NSHostingView(rootView: SettingsView(line: nil, section: chosen))
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("Settings")
        window.contentView = host
        window.titlebarAppearsTransparent = true

        // `CLOTHESPEG_SETTINGS_FLIP=inbox|peek|formatted` moves one of the
        // answers after the page has already read it, the way the menu bar does,
        // and then renders. This is the only check that can see the fault it
        // exists for: the page reads its answers once on the way in, the window
        // is kept alive rather than rebuilt, and so a picture taken after a flip
        // shows the old tick unless the page is listening. A picture taken
        // without a flip cannot fail, and so cannot prove anything.
        //
        // The real answers are put back afterwards, exactly as they were —
        // including the ones that were never there, which is why the restore
        // removes rather than writes a default. All of them are saved whether or
        // not this run flips them, because an answer left behind by a rehearsal
        // is the user's setting changed without their asking.
        let flip = ProcessInfo.processInfo.environment["CLOTHESPEG_SETTINGS_FLIP"]
        let answers = [Inbox.enabledDefaultsKey, "quietHang", FormatCopy.defaultsKey]
        let savedAnswers = answers.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(answers, savedAnswers) { restore(key, value) }
        }

        // SwiftUI lays out on the run loop, not on `layoutSubtreeIfNeeded`: a
        // bitmap taken straight away is a picture of an empty window, which
        // reads as "nothing renders" rather than "nothing had run yet".
        func pump() {
            for _ in 0..<3 {
                window.displayIfNeeded()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        pump()

        if let flip {
            switch flip {
            case "inbox": Inbox.screenshotInboxEnabled.toggle()
            case "peek": AppDelegate.peeksAtNew.toggle()
            case "formatted": FormatCopy.isEnabled.toggle()
            default: print("settings: no such flip '\(flip)'")
            }
            print("settings: flipped \(flip) after the page had read its answers")
            pump()
        }

        let shot = window.contentView?.superview ?? host
        guard let rep = shot.bitmapImageRepForCachingDisplay(in: shot.bounds) else {
            print("settings: could not make a bitmap for \(shot.bounds)")
            return
        }
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            window.backgroundColor.setFill()
            NSBezierPath(rect: shot.bounds).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        shot.cacheDisplay(in: shot.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("settings: could not encode the bitmap")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("settings: wrote \(path) (\(Int(shot.bounds.width))×\(Int(shot.bounds.height)), "
                  + "page \(chosen.rawValue))")
        } catch {
            print("settings: \(error)")
        }
    }

    /// Puts a preference back to the exact state it was read in: a value that
    /// was there is written again, and one that was never there is removed
    /// rather than given a default. Writing `false` where nothing existed is
    /// not the same answer — it is a record that somebody once said no.
    private static func restore(_ key: String, _ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Renders the space-preview window offscreen, at whatever size it is
    /// asked for.
    ///
    /// The window has no chrome and no numbers worth trusting, but it has one
    /// thing that is easy to get wrong and invisible until it is: the pin sits
    /// on the paper's corner, and the window can now be dragged to any size.
    /// Only a picture answers "is the pin still on the card, and does it read
    /// as something that can be pressed". The one printed number is the pin's
    /// frame, which has to change with the window — a number that cannot
    /// differ is not a check.
    static func renderZoom(to path: String, size: CGSize, pinned: Bool, dark: Bool,
                           hovering: Bool, opacity: CGFloat) {
        if dark {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        let sample = """
        The window is the same whatever is in it, so the reader learns where to \
        look and a window that changes shape between a note and a picture reads \
        as two different things rather than the same one. This paragraph is here \
        to be wrapped, scrolled and read at whatever size the window happens to \
        be, which is the whole of what pinning it open is for.
        """
        let picture = ProcessInfo.processInfo.environment["CLOTHESPEG_ZOOM_IMAGE"]
        let payload: Payload = picture.map { .image(URL(fileURLWithPath: $0)) }
            ?? .text(sample, isCode: false)
        let preview = ZoomPreview(payload: payload,
                                  origin: Origin(), anchor: .zero, qrcodes: nil)
        let host = NSHostingView(rootView: ZoomCard(preview: preview))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        let pin = PinButton()
        let slider = OpacitySlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
        slider.controlSize = .small
        let pane = ZoomPane(host: host, pin: pin, opacity: slider)
        let window = ZoomWindow(content: pane)
        window.controls = [pin, slider]
        window.setPinned(pinned)
        pane.setPinned(pinned)
        pane.rehearse(hovering: hovering, value: opacity)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: 200, y: 200))

        // Where the pointer is, as far as the window is concerned.
        //
        // The cursor timer reads the real pointer, which is nowhere near this
        // window — so left to itself it concludes nobody is pointing at the
        // card, `hovering` goes false and the slider fades out before the
        // photograph is taken. Told where to look instead: on the paper when
        // the picture is of a hovered window, off the screen when it is not.
        let inside = NSPoint(x: 120, y: 120)
        pane.pointerLocation = hovering
            ? { window.convertPoint(toScreen: inside) }
            : { NSPoint(x: -20_000, y: -20_000) }
        // The log belongs to the app, not to a rehearsal with a made-up
        // pointer: a record of cursors nobody moved would be worse than none.
        pane.logsCursor = false

        // SwiftUI lays out on the run loop, not on `layoutSubtreeIfNeeded`.
        for _ in 0..<3 {
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        guard let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else {
            print("zoom: could not make a bitmap for \(pane.bounds)")
            return
        }
        // A neutral ground behind the card: the card's own paper is the thing
        // being looked at, and a transparent PNG of white-on-nothing shows
        // nothing about where its edge is.
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(white: dark ? 0.22 : 0.62, alpha: 1).setFill()
            NSBezierPath(rect: pane.bounds).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        pane.cacheDisplay(in: pane.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("zoom: could not encode the bitmap")
            return
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point,
                                                 modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1,
                                                 pressure: 1) else { return }
            window.sendEvent(event)
        }

        // Rehearse a resize: press the right edge and pull 40 out.
        let sizeBefore = window.frame.size
        send(.leftMouseDown, NSPoint(x: size.width - 4, y: size.height / 2))
        send(.leftMouseDragged, NSPoint(x: size.width + 36, y: size.height / 2))
        send(.leftMouseUp, NSPoint(x: size.width + 36, y: size.height / 2))
        let grew = Int(window.frame.width - sizeBefore.width)

        // The top edge as well. The cursor offers a vertical arrow up there,
        // and a resize it promises but the press does not perform is exactly
        // what was reported as "a cursor that does nothing".
        let heightBefore = window.frame.height
        let topY = window.frame.height - 4
        send(.leftMouseDown, NSPoint(x: window.frame.width / 2, y: topY))
        send(.leftMouseDragged, NSPoint(x: window.frame.width / 2, y: topY + 40))
        send(.leftMouseUp, NSPoint(x: window.frame.width / 2, y: topY + 40))
        let taller = Int(window.frame.height - heightBefore)

        // Where the paper is, found rather than assumed.
        //
        // At 640×440 the point (120,120) happens to be paper; at the smallest
        // size the paragraph has grown into it, and a hard-coded point turns
        // the page shrinking into a failing test. Sampling also answers a
        // question worth having a number for: how much of the card can be
        // grabbed at all, which is what makes dragging a text card easy or
        // awkward.
        func samples() -> [NSPoint] {
            var points: [NSPoint] = []
            for y in stride(from: 24.0, to: window.frame.height - 24, by: 12) {
                for x in stride(from: 24.0, to: window.frame.width - 24, by: 12) {
                    points.append(NSPoint(x: x, y: y))
                }
            }
            return points
        }
        let grid = samples()
        let grabby = grid.filter {
            !window.isOnControl($0) && (pane.hitTest($0)?.mouseDownCanMoveWindow ?? false)
        }
        let grabShare = grid.isEmpty ? 0 : Int(100 * Double(grabby.count) / Double(grid.count))
        let paper = grabby.first ?? NSPoint(x: 40, y: 40)
        let textPoint = grid.first {
            !window.isOnControl($0) && !(pane.hitTest($0)?.mouseDownCanMoveWindow ?? true)
        } ?? NSPoint(x: size.width / 2, y: size.height / 2)

        // Rehearse a move: press on the paper, drag 50 left and 20 down, let
        // go. The window has to come out 50 and 20 somewhere else — a move
        // that cannot be measured is a move nobody checked, and this one has
        // already been wrong twice by looking right in the source.
        let before = window.frame.origin
        send(.leftMouseDown, paper)
        send(.leftMouseDragged, NSPoint(x: paper.x + 50, y: paper.y - 20))
        send(.leftMouseUp, NSPoint(x: paper.x + 50, y: paper.y - 20))
        let movedX = Int(window.frame.origin.x - before.x)
        let movedY = Int(window.frame.origin.y - before.y)

        // What the move depends on: a press on the paper has to be able to
        // take the window, and a press on the text must not. Two booleans
        // that can differ, printed every time, so a change under this line
        // shows up as a change in the line.
        let low = pane.hitTest(paper)?.mouseDownCanMoveWindow ?? false
        let high = pane.hitTest(textPoint)?.mouseDownCanMoveWindow ?? false
        print("zoom targets: edge \(window.edge(at: NSPoint(x: 4, y: size.height / 2)) != nil), "
              + "paper moves \(low) at \(Int(paper.x)),\(Int(paper.y)) (\(grabShare)% grabbable), "
              + "text selects \(!high) at \(Int(textPoint.x)),\(Int(textPoint.y)), "
              + "pin is a control \(window.isOnControl(NSPoint(x: pin.frame.midX, y: pin.frame.midY)))")

        // The cursor, actually looked at.
        //
        // The line above says which branch *should* be taken. That is an
        // argument about the code, not a check on it. These four put the
        // pointer in four places, call the very entry point the timer calls,
        // and read `NSCursor.current` back — a cursor that was never set stays
        // at the poison and reports WRONG.
        //
        // Each probe poisons with a cursor that is *not* the expected one, so
        // a pass cannot be the previous probe's answer left lying there. The
        // mouse-moved path this replaced could not be tested at all; this one
        // can, because the position is read rather than delivered.
        pane.rehearse(hovering: true, value: opacity)
        func expected(_ cursor: NSCursor) -> NSCursor { pinned ? cursor : .arrow }
        func probeCursor(_ label: String, at point: NSPoint,
                         expecting want: NSCursor, poisoning poison: NSCursor) -> String {
            poison.set()
            pane.pointerLocation = { window.convertPoint(toScreen: point) }
            pane.tickCursor()
            return "\(label) " + (NSCursor.current == want ? "ok" : "WRONG")
        }
        // What the middle of the card should offer: a paragraph is selected,
        // a picture is grabbed. The probe has to be told which, or it would
        // call the right answer wrong on half the runs — an image has no text
        // cursor anywhere in it.
        let contentIsText: Bool = {
            if case .text = payload { return true }
            return false
        }()
        let contentCursor: NSCursor = contentIsText ? .iBeam : .openHand
        let contentPoison: NSCursor = contentIsText ? .openHand : .iBeam
        let probes = [
            probeCursor("edge", at: NSPoint(x: 4, y: size.height / 2),
                        expecting: expected(window.cursor(for: .left)), poisoning: .openHand),
            probeCursor("paper", at: paper,
                        expecting: expected(.openHand), poisoning: .iBeam),
            probeCursor("text", at: textPoint,
                        expecting: expected(contentCursor), poisoning: contentPoison),
            probeCursor("pin", at: NSPoint(x: pin.frame.midX, y: pin.frame.midY),
                        expecting: .arrow, poisoning: .openHand),
        ]
        print("zoom cursors: " + probes.joined(separator: ", "))
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("zoom: wrote \(path) (\(Int(size.width))×\(Int(size.height)), "
                  + "pinned \(pinned), pin at \(Int(pin.frame.minX)),\(Int(pin.frame.minY)), "
                  + "slider \(Int(slider.frame.width)) wide at \(Int(slider.frame.minX)),"
                  + "\(Int(slider.frame.minY)), "
                  + "card alpha \(String(format: "%.2f", host.alphaValue)), "
                  + "drag paper \(low) text \(high), "
                  + "moved \(movedX),\(movedY) of 50,-20, "
                  + "widened \(grew) of 40, "
                  + "heightened \(taller) of 40, "
                  + "keyable \(window.keyable)")
        } catch {
            print("zoom: \(error)")
        }
    }

    /// Loads `picture`, renders the editor window at `size`, writes a PNG to
    /// `path`, and prints anything that will not fit.
    static func render(picture: String, to path: String,
                       size: NSSize = NSSize(width: 980, height: 700)) {
        // The appearance has to be decided before the views are built: colours
        // resolved in one appearance and cached in a layer do not follow a
        // change that arrives afterwards, and a window rendered that way is a
        // picture of a bug that does not exist.
        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_DARK"] != nil {
            // `NSApp` is nil until the shared application exists, and the hook
            // in `main.swift` runs before it is asked for.
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }

        let url = URL(fileURLWithPath: picture)
        // Read before anything is written. This process writes to the real
        // preferences — the app has one domain and the harness runs in it — so
        // whatever happens below has to be undone, and "never chosen" is a
        // different state from "chosen on": the default only holds while nobody
        // has answered.
        let storedHints = UserDefaults.standard.object(forKey: ShortcutHints.defaultsKey)
        defer {
            if let storedHints {
                UserDefaults.standard.set(storedHints, forKey: ShortcutHints.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ShortcutHints.defaultsKey)
            }
        }
        // The corners bare, for the other half of the comparison. Set through
        // `UserDefaults` rather than through the property so that no
        // notification goes out: the window does not exist yet, and the only
        // thing being asked for is what a new window would open with.
        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_NOHINTS"] != nil {
            UserDefaults.standard.set(false, forKey: ShortcutHints.defaultsKey)
        }
        let controller = EditorWindowController(url: url)
        controller.preview(url: url)

        // Every tool is visited once before the shot is taken. The property
        // strip hides its sliders and brings them back as the tool changes, and
        // a stack view that puts a returned control in the wrong slot only does
        // so after it has been away — a picture of the first state would never
        // catch it.
        for tool in EditorTool.allCases { controller.select(tool) }

        // Which tool is in hand changes what the strip says, so a harness that
        // always renders the empty one would only ever check the empty state.
        // The cursor tool unless one is named — stated rather than inherited,
        // because the walk above ends on whichever tool is last in the enum.
        let name = ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_TOOL"]
        controller.select(name.flatMap(EditorTool.init(rawValue:)) ?? .select)

        // A frame left standing under V, with no hand in the picture. The
        // grips are the state a normal shot can never reach: drawing one ends
        // in a crop, and switching tools used to throw the frame away.
        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_CROPVISUAL"] != nil {
            controller.previewCrop(CGRect(x: 180, y: 140, width: 620, height: 420))
            controller.select(.select)
        }

        let window = controller.previewWindow
        window.setContentSize(size)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()

        // The crop drill goes last: it crops, and everything after it would be
        // measuring a picture that is no longer the one on disk.
        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_ITALIC"] != nil {
            italicDrill(controller, window: window)
        }

        // Zoom is a setting the picture cannot report on its own, and a
        // screenshot of "100%" does not prove that the number reached the
        // canvas.
        if let zoom = ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_ZOOM"] {
            controller.previewZoom(zoom == "fit" ? nil : Double(zoom).map { CGFloat($0) })
            view.layoutSubtreeIfNeeded()
        }

        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_ZOOMDRILL"] != nil {
            zoomDrill(controller, window: window)
            drawerDrill(controller, window: window)
        }

        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_DRILL"] != nil {
            // Adjusting a frame must leave the picture alone, so it goes first
            // and the double-click drill still sees the file it was given.
            cropAdjustDrill(controller, window: window)
            cropDrill(controller, window: window)
        }

        // The bars fade while something is being dragged, which is a state a
        // still picture cannot otherwise reach.
        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_FADE"] != nil {
            controller.previewFade()
            view.layoutSubtreeIfNeeded()
        }

        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_PLACE"] != nil {
            placementDrill(controller)
        }

        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_HINTS"] != nil {
            hintDrill(controller)
        }

        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_SLIDER"] != nil {
            sliderDrill(controller)
        }

        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_INK"] != nil {
            inkDrill(controller)
        }

        // The loupe is a hover state, and a still picture has no mouse. This
        // puts it on a known pixel before the shot, so the grid, the outlined
        // square and the hex are all in the picture being looked at.
        if let eye = ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_EYE"] {
            let parts = eye.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2,
               let canvas = view.subviews.first(where: { $0 is EditorCanvasView })
                   as? EditorCanvasView {
                controller.select(.eyedropper)
                view.layoutSubtreeIfNeeded()
                canvas.previewHover(x: CGFloat(parts[0]), y: CGFloat(parts[1]))
                canvas.needsDisplay = true
            } else {
                print("eye: WRONG — expected two picture coordinates, got \(eye)")
            }
        }

        // The title bar is part of what is being looked at now: the file name
        // and its size moved up there, so a shot of the content view alone
        // would leave out the one line the round was about. The frame view is
        // the content view's superview — the window's own frame, title bar and
        // traffic lights included.
        let shot = window.contentView?.superview ?? view

        guard let rep = shot.bitmapImageRepForCachingDisplay(in: shot.bounds) else {
            print("preview: could not make a bitmap for \(shot.bounds)")
            return
        }
        // The content view has no ground of its own — the window paints behind
        // it — so a cached bitmap of the content view alone comes out
        // transparent there, which reads as white and makes everything drawn in
        // light ink invisible. The window's own colour goes underneath first.
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            window.backgroundColor.setFill()
            NSBezierPath(rect: shot.bounds).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        shot.cacheDisplay(in: shot.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("preview: could not encode the bitmap")
            return
        }
        // A silent failure here would be a picture of nothing, taken as
        // evidence that the layout is fine.
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("preview: wrote \(path) (\(data.count) bytes, \(Int(shot.bounds.width))×\(Int(shot.bounds.height)), title \"\(window.title)\")")
        } catch {
            print("preview: \(error)")
        }
        reportFitting(view)
        reportBars(controller, at: size)
        reportColourSampler()
        reportCropPixels()
        reportColourNeighbourhood()
        reportColourScale()
        reportTagSize()

        if ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_EYE"] != nil {
            tagSizePresetDrill(controller, window: window)
            tagPickDrill(controller, window: window)
            eyeDrill(controller, window: window)
        }

        if let second = ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_CHECK"] {
            checkEditor(url: url, second: URL(fileURLWithPath: second))
        }
    }

    /// Two questions a picture cannot answer: whether a second file really gets
    /// a second window, and whether the style book survives a round trip.
    ///
    /// The style check puts the user's own numbers back afterwards. A check
    /// that leaves the preferences it was checking changed is not a check, it
    /// is a side effect.
    private static func checkEditor(url: URL, second: URL) {
        ImageEditor.shared.open(url)
        ImageEditor.shared.open(url)
        let afterSameFile = ImageEditor.shared.previewOpenCount
        ImageEditor.shared.open(second)
        let afterSecondFile = ImageEditor.shared.previewOpenCount
        print("check: same file twice → \(afterSameFile) window(s); "
              + "then a second file → \(afterSecondFile) window(s)")

        let saved = EditorStyleStore.load()
        var arrow = EditorTool.arrow.defaultStyle
        arrow.width = 17
        EditorStyleStore.save([.arrow: arrow])
        let readBack = EditorStyleStore.load()[.arrow]?.width ?? -1
        EditorStyleStore.save(saved)
        print("check: wrote width 17, read back \(readBack)")
    }

    /// Presses 斜体 the way a hand would, and says whether the style heard it.
    ///
    /// The font layer was checked separately — a nib and a system font converted
    /// to italic really do draw different glyphs — so the question left is
    /// whether the press travels. Sending the chip's own action is the same road
    /// a click takes: target, action, and nothing skipped in between.
    private static func italicDrill(_ controller: EditorWindowController, window: NSWindow) {
        controller.select(.text)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView,
              let chip = button(tipped: L("Italic"), in: view) else {
            print("italic: no 斜体 chip to press")
            return
        }
        let press = {
            NSApp.sendAction(chip.action ?? #selector(NSResponder.doCommand(by:)),
                             to: chip.target, from: chip)
        }
        let before = controller.previewTextStyle.isItalic
        press()
        let pressed = controller.previewTextStyle.isItalic
        let canvas = view.subviews.first(where: { $0 is EditorCanvasView }) as? EditorCanvasView
        let caret = canvas?.previewCaretFontName() ?? "no canvas"
        // Pressed a second time: the drill has to leave the tool where it found
        // it, or the check becomes a preference change.
        press()
        let restored = controller.previewTextStyle.isItalic

        print("italic: \(before) → \(pressed) → \(restored); "
              + "the caret field would use \(caret)")
        print(pressed != before && restored == before
              ? "italic: the press reaches the style, and the caret follows it"
              : "italic: FAILED — the press or the caret font is not following")
    }

    private static func button(tipped tip: String, in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.toolTip == tip { return button }
        for sub in root.subviews {
            if let found = button(tipped: tip, in: sub) { return found }
        }
        return nil
    }

    /// Draws a frame under C, presses V, and adjusts the frame V left standing.
    /// The checks are the frame itself rather than the picture: an applied crop
    /// would leave the next drill measuring a different image, so the frame is
    /// dismissed with Escape at the end.
    private static func cropAdjustDrill(_ controller: EditorWindowController, window: NSWindow) {
        guard let canvas = window.contentView?.subviews.first(where: { $0 is EditorCanvasView })
                as? EditorCanvasView else {
            print("crop adjust: WRONG — no canvas")
            return
        }
        controller.previewZoom(nil)
        controller.select(.crop)
        window.contentView?.layoutSubtreeIfNeeded()

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            canvas.convert(controller.previewViewPoint(x, y), to: nil)
        }
        func send(_ type: NSEvent.EventType, _ at: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }
        func drag(_ from: NSPoint, _ to: NSPoint) {
            send(.leftMouseDown, from)
            send(.leftMouseDragged, to)
            send(.leftMouseUp, to)
        }

        drag(point(60, 60), point(260, 200))
        let drawn = controller.previewCropRect
        controller.select(.select)
        let afterV = controller.previewCropRect
        guard let frame = afterV else {
            print("crop adjust: WRONG — V threw the frame away")
            return
        }
        // The bottom-right grip sits at (maxX, minY) in picture pixels, which
        // is bottom-left space: pulling it down and right grows the frame.
        drag(point(frame.maxX, frame.minY), point(frame.maxX + 40, frame.minY - 30))
        let resized = controller.previewCropRect
        if let middle = resized {
            drag(point(middle.midX, middle.midY), point(middle.midX + 20, middle.midY + 10))
        }
        let moved = controller.previewCropRect

        if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: 53) {
            canvas.keyDown(with: esc)
        }
        let cleared = controller.previewCropRect == nil

        let kept = drawn != nil && afterV == drawn
        let grew = resized.map { $0.width > frame.width + 20 && $0.height > frame.height + 15 } ?? false
        let shifted = moved.map { $0.origin.x > (resized?.origin.x ?? 0) + 10 } ?? false
        let shape = [drawn, afterV, resized, moved].map {
            $0.map { "\(Int($0.width))×\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "nil"
        }.joined(separator: " → ")
        print(kept && grew && shifted && cleared
              ? "crop adjust: V kept \(shape), grip + move, esc cleared ok"
              : "crop adjust: WRONG — \(shape) (kept \(kept), grew \(grew), moved \(shifted), cleared \(cleared))")
    }

    /// Draws a crop frame and double-clicks it, the way a hand would.
    ///
    /// The one part of this round that a still picture cannot show: the frame
    /// now applies on a double-click rather than on a button, and "the code
    /// reads right" is not evidence that the events arrive. So the events are
    /// made here and sent through the window, which is the same road a real
    /// click takes: hit test, `mouseDown`, `mouseDragged`, `mouseUp`.
    private static func cropDrill(_ controller: EditorWindowController, window: NSWindow) {
        guard let canvas = window.contentView?.subviews.first(where: { $0 is EditorCanvasView })
        else { print("drill: no canvas"); return }

        // Back to fitting the window first. The points below are fractions of
        // the picture, and at 200% — which is where the zoom drill leaves it —
        // the first corner can land outside the visible canvas, so the drag
        // never reaches it and the drill fails for a reason that has nothing to
        // do with cropping. A drill that only passes when it runs alone is a
        // drill nobody can trust.
        controller.previewZoom(nil)
        controller.select(.crop)
        window.contentView?.layoutSubtreeIfNeeded()

        let before = controller.previewPixelSize
        // Two corners in picture space, expressed in view space, then window
        // space — the canvas converts back on the way in. Picture space rather
        // than raw view points: at anything other than fit those are two
        // different places, and a drill that aims at the wrong one passes for
        // the wrong reason.
        let a = canvas.convert(controller.previewViewPoint(60, 60), to: nil)
        let b = canvas.convert(controller.previewViewPoint(260, 200), to: nil)

        func send(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 1) else {
                print("drill: could not make a \(type.rawValue) event at \(point)")
                return
            }
            // Handed straight to the canvas rather than through
            // `window.sendEvent`: a window that is not key swallows the first
            // mouse-down to take focus, and a window that was never ordered
            // front never becomes key. Hit testing is the part `sendEvent`
            // would add, and it is checked above instead.
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }

        // Where the clicks land, in case a later change to the layout puts the
        // canvas somewhere the points do not reach.
        if window.contentView?.hitTest(a) !== canvas || window.contentView?.hitTest(b) !== canvas {
            print("drill: the sample points no longer land on the canvas")
        }

        send(.leftMouseDown, a, clicks: 1)
        send(.leftMouseDragged, b, clicks: 1)
        send(.leftMouseUp, b, clicks: 1)
        let drawn = controller.previewPixelSize

        // The first click of the pair lands on the frame and must leave it
        // alone; the second is the one that applies it.
        send(.leftMouseDown, a, clicks: 1)
        send(.leftMouseUp, a, clicks: 1)
        let afterOneClick = controller.previewPixelSize
        send(.leftMouseDown, a, clicks: 2)
        send(.leftMouseUp, a, clicks: 2)
        let afterDoubleClick = controller.previewPixelSize

        print("drill: \(Int(before.width))×\(Int(before.height))"
              + " → drag \(Int(drawn.width))×\(Int(drawn.height))"
              + " → one click \(Int(afterOneClick.width))×\(Int(afterOneClick.height))"
              + " → double click \(Int(afterDoubleClick.width))×\(Int(afterDoubleClick.height))")
        let worked = drawn == before && afterOneClick == before && afterDoubleClick != before
        print(worked ? "drill: double-click crops, single click does not"
                     : "drill: FAILED — crop did not behave as asked")
    }

    /// Whether the three floating bars are still three.
    ///
    /// A single row of controls could only fail by running past the window; the
    /// bars are anchored left, centre and right, so they fail by meeting in the
    /// middle — which the overflow check cannot see, because nothing left.
    private static func reportBars(_ controller: EditorWindowController, at size: NSSize) {
        let frames = controller.previewBarFrames
        guard frames.count == 3 else {
            print("bars: \(frames.count) of 3 found")
            return
        }
        let gaps = [frames[1].minX - frames[0].maxX, frames[2].minX - frames[1].maxX]
        let tightest = gaps.min() ?? 0
        print(tightest > 0
              ? "bars: three, tightest gap \(Int(tightest)) pt at \(Int(size.width)) wide"
              : "bars: OVERLAP by \(Int(-tightest)) pt at \(Int(size.width)) wide")
    }

    /// Draws the same rectangle twice — once fitted, once at 200% — and reads
    /// back where the picture thinks it landed.
    ///
    /// Zoom puts a transform between the pointer and the marks, and the only
    /// way it goes wrong is quietly: the shape appears under the pointer and the
    /// stored rectangle is somewhere else, or a different size. So the drill
    /// aims at picture pixels through the same conversion the drawing uses, and
    /// then compares what was stored with what was asked for.
    private static func zoomDrill(_ controller: EditorWindowController, window: NSWindow) {
        guard let canvas = window.contentView?.subviews.first(where: { $0 is EditorCanvasView })
        else { print("zoom: no canvas"); return }
        controller.select(.rectangle)

        // Corners as fractions of the picture, so the drill works on whatever
        // picture it is given — including one a previous drill has just cropped
        // down to a few dozen pixels.
        let size = controller.previewPixelSize
        guard size.width > 20, size.height > 20 else {
            print("zoom: the picture is \(Int(size.width))×\(Int(size.height)), too small to aim at")
            return
        }

        let from = (x: size.width * 0.2, y: size.height * 0.2)
        let to = (x: size.width * 0.5, y: size.height * 0.5)

        func draw(_ tag: String) -> CGRect {
            window.contentView?.layoutSubtreeIfNeeded()
            let a = canvas.convert(controller.previewViewPoint(from.x, from.y), to: nil)
            let b = canvas.convert(controller.previewViewPoint(to.x, to.y), to: nil)
            func send(_ type: NSEvent.EventType, _ point: NSPoint) {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                case .leftMouseUp: canvas.mouseUp(with: event)
                default: break
                }
            }
            send(.leftMouseDown, a)
            send(.leftMouseDragged, b)
            send(.leftMouseUp, b)
            let got = controller.previewLastMark ?? .zero
            print("zoom: \(tag) → stored \(Int(got.minX)),\(Int(got.minY)) "
                  + "\(Int(got.width))×\(Int(got.height))")
            return got
        }

        controller.previewZoom(nil)
        let fitted = draw("fit, \(controller.previewZoomLabel)")
        controller.previewZoom(2)
        let doubled = draw("200%, \(controller.previewZoomLabel)")

        let asked = CGRect(x: from.x, y: from.y,
                           width: to.x - from.x, height: to.y - from.y)
        let agrees = abs(fitted.width - asked.width) < 1.5 && abs(fitted.height - asked.height) < 1.5
            && abs(doubled.width - asked.width) < 1.5 && abs(doubled.height - asked.height) < 1.5
        print(agrees ? "zoom: the transform agrees with the drawing at both scales"
                     : "zoom: FAILED — the stored rectangle does not match the pointer")

        // The keys are the other road in, and an accessory app with no main menu
        // has only this one: a command key goes to whatever answers
        // `performKeyEquivalent`. Reading the code is not evidence that it does.
        func press(_ characters: String) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0) else { return }
            _ = canvas.performKeyEquivalent(with: event)
        }
        // From 50%, so that "back to one point per pixel" has somewhere to come
        // back from: on a picture whose fit already is 100%, ⌘0 and ⌘1 would
        // agree and the check would prove nothing.
        controller.previewZoom(0.5)
        press("0")
        let actual = controller.previewZoomLabel
        press("1")
        let fittedAgain = controller.previewZoomLabel
        press("-")
        let stepped = controller.previewZoomLabel
        print("zoom: from 50%, ⌘0 → \(actual), ⌘1 → \(fittedAgain), ⌘− → \(stepped)")
        print(actual == "100%"
              ? "zoom: the keys answer"
              : "zoom: FAILED — ⌘0 did not reach a hundred percent")

        // Two different meanings of "actual size" must both be on offer, and
        // the screen one is a view-only rung: 2x -> 0.5, with scale 1 still
        // meaning one picture pixel to one point for every mark and export.
        let titles = controller.previewZoomMenuTitles
        let screenRung = titles.contains { $0.contains(L("Screen Actual Size")) }
        let labelled = titles.contains { $0.hasPrefix("100%") && $0.contains(L("Pixel for pixel")) }
        let half = EditorWindowController.screenActualZoom(for: 2)
        let rungs = titles.filter { $0.contains("%") }
        let keepsRungs = ["50%", "200%", "400%"].allSatisfy { rungs.contains($0) }
        print(screenRung && labelled && keepsRungs && half == 0.5
              ? "zoom menu: \(rungs.joined(separator: " / "))"
              : "zoom menu: WRONG — \(rungs), 2x gave \(half)")

        // Ten-point steps, and the first one snaps to a round ten: a fit that
        // happened to land on 73% steps to 80%, not to 83%.
        controller.previewZoom(0.73)
        var ladder: [String] = [controller.previewZoomLabel]
        for _ in 0..<2 { press("+"); ladder.append(controller.previewZoomLabel) }
        for _ in 0..<2 { press("-"); ladder.append(controller.previewZoomLabel) }
        print("zoom: 10-point steps \(ladder.joined(separator: " → "))")

        // The hand is the only thing that moves the view, and the only drag that
        // must leave no mark behind.
        controller.previewZoom(2)
        controller.select(.hand)
        window.contentView?.layoutSubtreeIfNeeded()
        let start = controller.previewImageOrigin
        let marksBefore = controller.previewMarkCount
        let anchor = canvas.convert(NSPoint(x: 200, y: 200), to: nil)
        let dragged = canvas.convert(NSPoint(x: 260, y: 240), to: nil)
        func hand(_ type: NSEvent.EventType, _ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }
        hand(.leftMouseDown, anchor)
        hand(.leftMouseDragged, dragged)
        hand(.leftMouseUp, dragged)
        let end = controller.previewImageOrigin
        let moved = (x: end.x - start.x, y: end.y - start.y)
        print("pan: dragged 60,40 → moved \(Int(moved.x)),\(Int(moved.y)); "
              + "marks \(marksBefore) → \(controller.previewMarkCount)")
        print(abs(moved.x - 60) < 1.5 && abs(moved.y - 40) < 1.5
              && controller.previewMarkCount == marksBefore
              ? "pan: the hand moves the picture and draws nothing"
              : "pan: FAILED — the picture did not follow the hand")
    }

    /// Presses the tool already in hand, twice, and watches the drawer.
    ///
    /// The fold is the only way to get the drawer out of the way without
    /// putting the tool down, and it is the only control in the window whose
    /// second press means something different from its first.
    private static func drawerDrill(_ controller: EditorWindowController, window: NSWindow) {
        controller.select(.rectangle)
        window.contentView?.layoutSubtreeIfNeeded()
        let open = controller.previewDrawerHidden
        controller.previewPressTool(.rectangle)
        let folded = controller.previewDrawerHidden
        controller.previewPressTool(.rectangle)
        let unfolded = controller.previewDrawerHidden
        controller.select(.select)
        let onCursor = controller.previewDrawerHidden
        print("drawer: rectangle open=\(!open), press again folded=\(folded), "
              + "press again unfolded=\(!unfolded), cursor hidden=\(onCursor)")
        print(open == false && folded && unfolded == false && onCursor
              ? "drawer: follows the tool, and folds on a second press"
              : "drawer: FAILED — one of the four states is wrong")
    }

    /// Whether the letters in the corners are the right letters, and whether
    /// the switch reaches a window that is already open.
    ///
    /// A screenshot can show that there is *something* in the corner; it cannot
    /// say which key each button got, and a row where 裁剪 says "V" would look
    /// perfectly fine. So the letters are compared with the tools they belong
    /// to. The switch is then thrown the way the settings page throws it —
    /// through the property, which is the only road that posts.
    private static func hintDrill(_ controller: EditorWindowController) {
        let shown = controller.previewShortcutHints
        let asked = EditorTool.allCases.map { $0.key.uppercased() }
        print("hints: \(shown.count) of \(asked.count) corners carry a key — "
              + shown.joined(separator: " "))
        guard shown == asked else {
            print("hints: showing \(shown) where \(asked) was asked for")
            print("hints: FAILED — a corner is carrying the wrong letter, or none")
            return
        }

        // Off, then back. The drill leaves the preference where it found it: a
        // check that changes what it was checking is a side effect.
        ShortcutHints.isEnabled = false
        let off = controller.previewShortcutHints
        ShortcutHints.isEnabled = true
        let back = controller.previewShortcutHints
        print("hints: switch off → \(off.count) corners, back on → \(back.count)")
        print(off.isEmpty && back == asked
              ? "hints: the switch reaches a window that is already open"
              : "hints: FAILED — the switch did not reach the corners")

        // One line, not one height per chip. A tool may be added and the check
        // has to keep counting for itself. A chip is a 30 × 26 square and nothing
        // in it may push that square around — but a borderless `NSButton` still
        // reports the bezel it would have had, and the stack view honours that
        // report. The failure is silent, per-chip, and worst on the one glyph
        // drawn by hand rather than looked up, so it is measured rather than
        // looked at.
        let lines = controller.previewHintBaselines
        let spread = (lines.max() ?? 0) - (lines.min() ?? 0)
        print("hints: the corners are drawn at "
              + lines.map { String(format: "%.1f", $0) }.joined(separator: " "))
        print(lines.count == asked.count && spread < 0.5
              ? "hints: all \(asked.count) on one line (spread \(String(format: "%.1f", spread)) pt)"
              : "hints: FAILED — the corners span \(String(format: "%.1f", spread)) pt")
    }

    /// A picture whose two halves are known, so the sampler cannot get away
    /// with reading the wrong row: the top is blue, the bottom is red. The
    /// rep counts its rows from the top while the canvas draws them from the
    /// bottom, and this is the one check that can see the difference.
    private static func reportColourSampler() {
        let side = 8
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("colour: WRONG — could not build the test picture")
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        guard let image = ctx.makeImage() else {
            print("colour: WRONG — could not finish the test picture")
            return
        }
        let upper = ColourSampler.colour(at: CGPoint(x: 2, y: 7), in: image)
            .map(ColourSampler.hex) ?? "nil"
        let lower = ColourSampler.colour(at: CGPoint(x: 2, y: 0), in: image)
            .map(ColourSampler.hex) ?? "nil"
        print(upper == "#0000FF" && lower == "#FF0000"
              ? "colour: top \(upper), bottom \(lower) ok"
              : "colour: WRONG — top \(upper), bottom \(lower) (expected #0000FF / #FF0000)")
    }

    /// A crop is a reading of the picture's rows, not of the rectangle's
    /// arithmetic. The frame and every mark are measured from the bottom-left,
    /// while `CGImage.cropping(to:)` counts rows from the top; a picture split
    /// into two known halves is the only check that can see which half came
    /// back. Checking the resulting size alone cannot: the wrong half is
    /// exactly the same number of pixels.
    private static func reportCropPixels() {
        let side = 8
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("crop pixels: WRONG — could not build the test picture")
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        guard let image = ctx.makeImage() else {
            print("crop pixels: WRONG — could not finish the test picture")
            return
        }
        let lower = EditorDocument(source: image)
        let upper = EditorDocument(source: image)
        let croppedBottom = lower.crop(to: CGRect(x: 0, y: 0, width: side, height: side / 2))
        let croppedTop = upper.crop(to: CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        let bottom = ColourSampler.colour(at: CGPoint(x: 2, y: 2), in: lower.source)
            .map(ColourSampler.hex) ?? "nil"
        let top = ColourSampler.colour(at: CGPoint(x: 2, y: 2), in: upper.source)
            .map(ColourSampler.hex) ?? "nil"
        let ok = croppedBottom && croppedTop && bottom == "#FF0000" && top == "#0000FF"
        print(ok ? "crop pixels: bottom \(bottom), top \(top) ok"
                 : "crop pixels: WRONG — bottom \(bottom), top \(top) (expected #FF0000 / #0000FF)")
    }

    /// A tag is drawn in picture pixels and the canvas scales the whole picture
    /// at once. On a 4K picture a fixed 148×44 tag comes out a quarter of the
    /// size it has on a 400-pixel one. Counting the opaque run across the pill
    /// on a fitted screen is the check, not the arithmetic that claims it.
    private static func reportColourScale() {
        let style = EditorTool.eyedropper.defaultStyle
        let small = ColourTagMark(anchor: CGPoint(x: 120, y: 90), colour: .blue,
                                  imageSize: CGSize(width: 400, height: 300), style: style)
        let big = ColourTagMark(anchor: CGPoint(x: 1200, y: 900), colour: .blue,
                                imageSize: CGSize(width: 4000, height: 3000), style: style)
        let cloned = (big.clone() as? ColourTagMark)?.unit ?? -1
        let units = small.unit == 1 && big.unit == 4 && cloned == 4
        let geometry = Int(small.pillForTesting.width) == 148
            && Int(small.pillForTesting.height) == 44
            && Int(big.pillForTesting.width) == 592
            && Int(big.pillForTesting.height) == 176
        let smallFitted = fittedPillWidth(400, into: 900) ?? -1
        let bigFitted = fittedPillWidth(4000, into: 900) ?? -1
        let fitted = smallFitted > 0 && bigFitted > 0
            && abs(smallFitted - bigFitted) <= smallFitted / 5
        print(units && geometry && fitted
              ? "tag scale: unit 1→4, pill 148×44→592×176, fitted \(smallFitted)→\(bigFitted) pt, "
                + "clone kept \(cloned) ok"
              : "tag scale: WRONG (unit \(small.unit)/\(big.unit)/\(cloned), "
                + "pill \(Int(small.pillForTesting.width))×\(Int(small.pillForTesting.height))"
                + "→\(Int(big.pillForTesting.width))×\(Int(big.pillForTesting.height)), "
                + "fitted \(smallFitted)→\(bigFitted))")
    }

    /// The size slider is not a second drawing: it is a multiplier on the very
    /// same `unit` the picture chose. Draw it at 1.0 and 2.0 and measure the
    /// opaque run, so a slider that only changes its caption cannot pass.
    private static func reportTagSize() {
        let style = EditorTool.eyedropper.defaultStyle
        let tag = ColourTagMark(anchor: CGPoint(x: 120, y: 90), colour: .blue,
                                imageSize: CGSize(width: 400, height: 300), style: style)
        let one = tag.pillForTesting.width
        tag.style.width = 2
        let two = tag.pillForTesting.width
        let cloneKeeps = (tag.clone() as? ColourTagMark)?.pillForTesting.width == two
        // A tag drawn bigger but still hit-tested at its old size would be
        // unclickable along its own right-hand edge.
        let farEdge = CGPoint(x: tag.pillForTesting.maxX - 4,
                              y: tag.pillForTesting.midY)
        let hit = tag.hitTest(farEdge, slack: 0)
        let boundsCover = tag.bounds.contains(farEdge)
        let fittedOne = fittedPillWidth(400, into: 900, multiplier: 1) ?? -1
        let fittedTwo = fittedPillWidth(400, into: 900, multiplier: 2) ?? -1
        let doubled = fittedOne > 0 && abs(fittedTwo - fittedOne * 2) <= fittedOne / 5
        let range = StyleField.tagScale.range(for: .eyedropper)
        let ok = one == 148 && two == 296 && cloneKeeps && hit && boundsCover && doubled
            && range.lowerBound == 0.5 && range.upperBound == 2.5 && style.width == 1
        print(ok
              ? "tag size: default 1.0x, slider 2.0x → pill 148→296, fitted \(fittedOne)→\(fittedTwo) pt, "
                + "clone/hit/bounds followed ok"
              : "tag size: WRONG — pill \(Int(one))→\(Int(two)), fitted \(fittedOne)→\(fittedTwo), "
                + "clone \(cloneKeeps), hit \(hit), bounds \(boundsCover), default \(style.width), "
                + "range \(range.lowerBound)…\(range.upperBound)")
    }

    /// Draws one tag the way the window would — the picture fitted into a fixed
    /// width, never enlarged — and measures the opaque run across its pill.
    private static func fittedPillWidth(_ imageSide: CGFloat, into window: CGFloat,
                                        multiplier: CGFloat = 1) -> Int? {
        let size = CGSize(width: imageSide, height: imageSide * 0.75)
        let tag = ColourTagMark(anchor: CGPoint(x: size.width * 0.3, y: size.height * 0.5),
                                colour: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1),
                                imageSize: size, style: EditorTool.eyedropper.defaultStyle)
        tag.style.width = multiplier
        let scale = min(window / size.width, 1)
        let width = Int(window)
        let height = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        tag.draw(in: ctx)
        ctx.flush()
        let rowBytes = ctx.bytesPerRow
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // Sweep every row rather than trusting a computed middle line: a
        // bitmap context's origin is its own business, and the widest run is
        // the pill's full width wherever it landed.
        var best = 0
        for row in 0..<height {
            let base: Int = row * rowBytes
            var run = 0
            for x in 0..<width {
                let pixel: Int = base + x * 4
                let alpha = Int(bytes[pixel + 3])
                if alpha > 180 { run += 1; best = max(best, run) } else { run = 0 }
            }
        }
        return best
    }

    /// The loupe asks for eleven pixels around the pointer, not one. A square
    /// that comes back the wrong size, or whose middle is a different pixel
    /// from the one-pixel reading, would draw a grid that lies about the click.
    /// Both samples sit on the far edge of the picture, where most of the
    /// neighbourhood is outside it and has to be filled with transparency.
    private static func reportColourNeighbourhood() {
        let side = 8
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("neighbourhood: WRONG — could not build the test picture")
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        guard let image = ctx.makeImage() else {
            print("neighbourhood: WRONG — could not finish the test picture")
            return
        }
        let upper = CGPoint(x: 3, y: 7)
        let lower = CGPoint(x: 3, y: 0)
        guard let top = ColourSampler.neighbourhood(in: image, around: upper, radius: 5),
              let bottom = ColourSampler.neighbourhood(in: image, around: lower, radius: 5) else {
            print("neighbourhood: WRONG — the edge of the picture gave no reading")
            return
        }
        let sizeOK = [top.image.width, top.image.height, bottom.image.width, bottom.image.height]
            .allSatisfy { $0 == 11 }
        let topHex = ColourSampler.hex(top.centre)
        let bottomHex = ColourSampler.hex(bottom.centre)
        let singleTop = ColourSampler.colour(at: upper, in: image).map(ColourSampler.hex) ?? "nil"
        let singleBottom = ColourSampler.colour(at: lower, in: image).map(ColourSampler.hex) ?? "nil"
        let ok = sizeOK && topHex == "#0000FF" && bottomHex == "#FF0000"
            && topHex == singleTop && bottomHex == singleBottom
        print(ok
              ? "neighbourhood: 11×11 at both edges, top \(topHex), bottom \(bottomHex) ok"
              : "neighbourhood: WRONG — \(top.image.width)×\(top.image.height), "
                + "top \(topHex) vs single \(singleTop), bottom \(bottomHex) vs single \(singleBottom)")

        // A tag is a reading pinned to a pixel. Move it from the blue half to
        // the red one and the hex has to come from the new pixel, while a clone
        // made before the move keeps the value it was born with.
        let tag = ColourTagMark(anchor: upper, colour: top.centre,
                                imageSize: CGSize(width: side, height: side),
                                style: EditorTool.eyedropper.defaultStyle)
        let snapshot = (tag.clone() as? ColourTagMark)?.hex ?? "nil"
        tag.translated(by: CGSize(width: 0, height: -7))
        tag.resample(from: image)
        let moved = tag.hex
        print(snapshot == "#0000FF" && moved == "#FF0000"
              ? "colour tag: \(snapshot) → \(moved) after a move, clone kept \(snapshot) ok"
              : "colour tag: WRONG — \(snapshot) → \(moved), expected #0000FF → #FF0000")
    }

    /// The picker's size is a setting for this visit to the tool: I opens the
    /// slider at 1.0x, a value chosen before the click lands on the new tag,
    /// and none of it survives into the style file or the next press of I.
    private static func tagSizePresetDrill(_ controller: EditorWindowController,
                                           window: NSWindow) {
        guard let canvas = window.contentView?.subviews.first(where: { $0 is EditorCanvasView })
                as? EditorCanvasView,
              let document = canvas.document else {
            print("tag size preset: WRONG — no canvas or document")
            return
        }
        let stored = UserDefaults.standard.object(forKey: EditorStyleStore.defaultsKey)
        defer {
            if let stored {
                UserDefaults.standard.set(stored, forKey: EditorStyleStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: EditorStyleStore.defaultsKey)
            }
        }
        controller.select(.eyedropper)
        window.contentView?.layoutSubtreeIfNeeded()
        let start = controller.previewPrimaryCaption
        let drawerOpen = controller.previewDrawerHidden == false
        let preset = controller.previewSlidePrimary(to: 1.5)
        // A drag does not write the style file; letting go does. Read after the
        // release, and read the file itself — `load()` deliberately drops this
        // key, so asking it would be a test that can never fail.
        controller.previewReleasePrimary()
        var remembered = false
        if let data = UserDefaults.standard.data(forKey: EditorStyleStore.defaultsKey),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            remembered = raw["eyedropper"] != nil
        }

        // A caption that says 1.5 is not proof the tag got it: the mark is
        // built from canvas.style, so click a known pixel and measure the pill.
        let x: CGFloat = 140, y: CGFloat = 110
        let location = canvas.convert(canvas.viewPoint(x: x, y: y), to: nil)
        func send(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            if type == .leftMouseDown { canvas.mouseDown(with: event) }
            if type == .leftMouseUp { canvas.mouseUp(with: event) }
        }
        let before = document.marks.count
        send(.leftMouseDown)
        send(.leftMouseUp)
        let pill = (document.marks.last { $0 is ColourTagMark } as? ColourTagMark)?
            .pillForTesting.width ?? -1
        document.undo()

        controller.select(.select)
        controller.select(.eyedropper)
        let again = controller.previewPrimaryCaption
        let expected = 148 * ColourTagMark.unit(for: document.pixelSize) * 1.5
        let ok = drawerOpen && start.contains("1.0") && preset.contains("1.5")
            && !remembered && document.marks.count == before
            && abs(pill - expected) <= 1 && again.contains("1.0")
        print(ok
              ? "tag size preset: I opens at \(start), 1.5x → pill \(Int(pill)) pt, "
                + "not stored, next I → \(again) ok"
              : "tag size preset: WRONG — start \(start), preset \(preset), "
                + "drawer \(drawerOpen), remembered \(remembered), "
                + "pill \(Int(pill)) vs \(Int(expected)), next I \(again), "
                + "marks \(before) → \(document.marks.count)")
    }

    /// A second click on a tag the picker just made used to draw another tag
    /// over it. A still picture cannot show this: the second click has to leave
    /// the mark count alone *and* put the tag in hand, because the size slider
    /// has no other way to reach a tag that is already on the picture.
    ///
    /// The tag is given a size the tool does not have before it is picked up.
    /// A drawer still answering 1.0x would mean the selection was reported but
    /// never used, which is the other half of the bug.
    private static func tagPickDrill(_ controller: EditorWindowController,
                                     window: NSWindow) {
        guard let canvas = window.contentView?.subviews.first(where: { $0 is EditorCanvasView })
                as? EditorCanvasView,
              let document = canvas.document else {
            print("tag pick: WRONG — no canvas or document")
            return
        }
        controller.previewZoom(nil)
        controller.select(.eyedropper)
        window.contentView?.layoutSubtreeIfNeeded()

        func click(_ picture: CGPoint) {
            let location = canvas.convert(canvas.viewPoint(x: picture.x, y: picture.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if type == .leftMouseDown { canvas.mouseDown(with: event) }
                if type == .leftMouseUp { canvas.mouseUp(with: event) }
            }
        }

        let before = document.marks.count
        click(CGPoint(x: 140, y: 110))
        guard let tag = document.marks.last(where: { $0 is ColourTagMark }) as? ColourTagMark,
              document.marks.count == before + 1 else {
            print("tag pick: WRONG — the first click did not make a tag")
            return
        }
        tag.style.width = 2
        let pill = tag.pillForTesting

        click(CGPoint(x: pill.midX, y: pill.midY))
        let afterPicked = document.marks.count
        let picked = canvas.selected === tag
        let caption = controller.previewPrimaryCaption

        // The fix must not turn the picker into a tool that only selects: a
        // click away from every tag still reads that pixel and draws a new one.
        click(CGPoint(x: 620, y: 520))
        let afterBlank = document.marks.count
        let dropped = canvas.selected == nil

        document.undo()
        document.undo()
        controller.select(.select)

        let ok = picked && afterPicked == before + 1 && caption.contains("2.0")
            && afterBlank == afterPicked + 1 && dropped
        print(ok
              ? "tag pick: I click → 1 tag, click the tag → selected at \(caption), "
                + "click away → 2 tags ok"
              : "tag pick: WRONG — picked \(picked), marks \(before) → \(afterPicked) → "
                + "\(afterBlank), caption \(caption), dropped \(dropped)")
    }

    /// The colour picker is three moves: a hover reads a pixel, a click writes
    /// the tag down, undo takes it back. Real mouse events at a known picture
    /// point are the only way to see `draft → document.add` happen, since
    /// `isWorthKeeping` quietly drops any mark it does not recognise.
    private static func eyeDrill(_ controller: EditorWindowController, window: NSWindow) {
        guard let canvas = window.contentView?.subviews.first(where: { $0 is EditorCanvasView })
                as? EditorCanvasView,
              let document = canvas.document else {
            print("eye: WRONG — no canvas or document")
            return
        }
        controller.previewZoom(nil)
        controller.select(.eyedropper)
        window.contentView?.layoutSubtreeIfNeeded()

        let x: CGFloat = 120, y: CGFloat = 90
        guard x < document.pixelSize.width, y < document.pixelSize.height else {
            print("eye: WRONG — the test pixel is outside the picture")
            return
        }
        canvas.previewHover(x: x, y: y)
        let loupe = canvas.previewLoupeHex ?? "nil"
        let before = document.marks.count
        let location = canvas.convert(canvas.viewPoint(x: x, y: y), to: nil)

        func send(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }
        send(.leftMouseDown)
        send(.leftMouseUp)
        let after = document.marks.count
        let tag = canvas.previewLastColourHex ?? "nil"
        document.undo()
        let undone = document.marks.count
        document.redo()
        let redone = document.marks.count

        let ok = loupe != "nil" && after == before + 1 && tag == loupe
            && undone == before && redone == after
        print(ok
              ? "eye: hover \(loupe), click → \(after - before) tag (\(tag)), "
                + "undo → \(undone), redo → \(redone) ok"
              : "eye: WRONG — hover \(loupe), marks \(before) → \(after) → "
                + "undo \(undone) → redo \(redone), tag \(tag)")

        // Moving the tag with the cursor tool takes a fresh reading. Look for a
        // pixel of a different colour first: a drag between two patches of the
        // same beige would prove nothing.
        controller.select(.select)
        var destination: CGPoint?
        for candidate in [CGPoint(x: 512, y: 512), CGPoint(x: 300, y: 270),
                          CGPoint(x: 700, y: 300), CGPoint(x: 512, y: 700)] {
            guard let hex = ColourSampler.colour(at: candidate, in: document.source)
                .map(ColourSampler.hex), hex != loupe else { continue }
            destination = candidate
            break
        }
        guard let target = destination else {
            print("eye: WRONG — no pixel of a different colour to drag onto")
            return
        }
        let from = canvas.convert(canvas.viewPoint(x: x, y: y), to: nil)
        let to = canvas.convert(canvas.viewPoint(x: target.x, y: target.y), to: nil)
        func sendAt(_ type: NSEvent.EventType, _ at: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }
        sendAt(.leftMouseDown, from)
        sendAt(.leftMouseDragged, to)
        sendAt(.leftMouseUp, to)
        let movedHex = canvas.previewLastColourHex ?? "nil"
        let expected = ColourSampler.colour(at: target, in: document.source)
            .map(ColourSampler.hex) ?? "nil"
        print(movedHex == expected && movedHex != tag
              ? "eye: dragged tag \(tag) → \(movedHex), matches the pixel it points at ok"
              : "eye: WRONG — dragged tag \(movedHex), expected \(expected)")

        // The drag left the tag in hand, which is the one state the size
        // slider acts on. Read the caption, move the knob, then undo: the
        // slider has to reach the drawing and undo has to take it back.
        let picked = canvas.selected as? ColourTagMark
        let drawerVisible = controller.previewDrawerHidden == false
        let caption = controller.previewPrimaryCaption
        let widthBefore = picked?.pillForTesting.width ?? -1
        let slideCaption = controller.previewSlidePrimary(to: 2)
        let widthAfter = (document.marks.last { $0 is ColourTagMark } as? ColourTagMark)?
            .pillForTesting.width ?? -1
        document.undo()
        let widthUndone = (document.marks.last { $0 is ColourTagMark } as? ColourTagMark)?
            .pillForTesting.width ?? -1
        let sliderOK = picked != nil && drawerVisible && widthBefore > 0
            && widthAfter == widthBefore * 2 && widthUndone == widthBefore
            && caption.contains("1.0") && slideCaption.contains("2.0")
        print(sliderOK
              ? "tag size slider: \(caption) → \(slideCaption), drawer open, "
                + "pill \(Int(widthBefore))→\(Int(widthAfter)), undo → \(Int(widthUndone)) ok"
              : "tag size slider: WRONG — \(caption) → \(slideCaption), "
                + "drawer open \(drawerVisible), pill "
                + "\(Int(widthBefore))→\(Int(widthAfter))→\(Int(widthUndone)), "
                + "picked \(picked != nil)")
    }

    /// Whether the number beside a slider follows the knob, or the mouse-up.
    ///
    /// A drill cannot perform the gesture — NSSlider's tracking loop would take
    /// the run loop and never give it back — so it does what the gesture does to
    /// the app: mark the slider as held, report a value, and read the caption
    /// before letting go. What it can prove is the part that was wrong: the
    /// caption changes on the report, not on the release. What it cannot prove
    /// is that AppKit sends those reports while the mouse is down — that is
    /// `isContinuous`, and it is asserted rather than assumed.
    private static func sliderDrill(_ controller: EditorWindowController) {
        // The user's own tool sizes live in the same domain this process is
        // running in, and this drill writes one. Put back exactly what was
        // there: "never chosen" is not the same as "chosen".
        let stored = UserDefaults.standard.object(forKey: EditorStyleStore.defaultsKey)
        defer {
            if let stored {
                UserDefaults.standard.set(stored, forKey: EditorStyleStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: EditorStyleStore.defaultsKey)
            }
        }
        func storedWidth(_ tool: EditorTool) -> CGFloat? {
            EditorStyleStore.load()[tool]?.width
        }

        controller.select(.rectangle)
        let continuous = controller.previewSlidersReportWhileDragging
        print("slider: \(continuous ? "both sliders report while the knob moves" : "the sliders wait for the mouse-up")")
        print(continuous
              ? "slider: the knob is heard from before it is let go"
              : "slider: FAILED — the knob only speaks on release")
        let from = controller.previewPrimaryCaption
        let before = storedWidth(.rectangle) ?? EditorTool.rectangle.defaultStyle.width

        // One report, mouse still down.
        let live = controller.previewSlidePrimary(to: 12)
        let midair = storedWidth(.rectangle) ?? EditorTool.rectangle.defaultStyle.width
        print("slider: \(from) → \(live) with the knob still held")
        print(live.hasSuffix("12") && live != from
              ? "slider: the caption follows the knob, not the mouse-up"
              : "slider: FAILED — the caption did not move until the drag ended")
        print(midair == before
              ? "slider: nothing written to the style file mid-drag (still "
                + String(format: "%.1f", midair) + ")"
              : "slider: FAILED — the file was written at "
                + String(format: "%.1f", midair) + " mid-drag")

        // Let go: the value goes to disk, once, and the next window opens on it.
        controller.previewReleasePrimary()
        let settled = storedWidth(.rectangle) ?? EditorTool.rectangle.defaultStyle.width
        print(settled == 12
              ? "slider: letting go writes it once (12)"
              : "slider: FAILED — the release left \(String(format: "%.1f", settled)) on disk")

        // Back to where it was, so the picture taken afterwards is the picture
        // of the editor as the user left it.
        controller.previewSlidePrimary(to: Double(before))
        controller.previewReleasePrimary()
    }

    /// Whether a colour chosen with a mark in hand is the next mark's colour
    /// too.
    ///
    /// The failure this exists to catch is invisible in a picture of the strip:
    /// the ring sat on the dot that had just been chosen, the drawer said black,
    /// and the next stroke came out red. What was wrong was never the drawing —
    /// it was that the colour press stopped at the selected mark and never
    /// reached the tool, so the choice had to be made again for every mark. So
    /// the drill does the sequence the user does: a mark in hand, then a colour,
    /// then read the tool's own colour back off the disk — the copy the next
    /// window opens on — rather than the one this window is showing.
    private static func inkDrill(_ controller: EditorWindowController) {
        // The tool sizes this drill overwrites are the user's. "Never chosen" is
        // not the same as "chosen", so an absent key is put back as absent.
        let stored = UserDefaults.standard.object(forKey: EditorStyleStore.defaultsKey)
        defer {
            if let stored {
                UserDefaults.standard.set(stored, forKey: EditorStyleStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: EditorStyleStore.defaultsKey)
            }
        }

        func srgb(_ colour: NSColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
            guard let resolved = colour?.usingColorSpace(.sRGB) else { return nil }
            return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }
        func hex(_ colour: NSColor?) -> String {
            guard let c = srgb(colour) else { return "nothing" }
            return String(format: "#%02x%02x%02x", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
        }
        func isSame(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let x = srgb(a), let y = srgb(b) else { return false }
            return abs(x.r - y.r) < 0.01 && abs(x.g - y.g) < 0.01 && abs(x.b - y.b) < 0.01
        }

        controller.select(.rectangle)

        // Colours the tool cannot already be holding. Without that care the
        // check compares the saved colour with itself and passes on a build
        // that writes nothing at all — which is exactly the build this drill
        // was written against, so it was caught passing before it ever ran.
        let already = EditorStyleStore.load()[.rectangle]?.color
        let well: NSColor = isSame(already, .black) ? .white : .black
        let dot: NSColor = isSame(already, .systemGreen) ? .systemBlue : .systemGreen

        // The well, with a frame still selected — the state after drawing one.
        let (mark, tool) = controller.previewInk(well, onSelectedMark: true)
        print("ink: the frame in hand became \(hex(mark)), the tool remembers \(hex(tool))")
        print(isSame(mark, well) && isSame(tool, well)
              ? "ink: a colour chosen while a mark is in hand is the next mark's too"
              : "ink: FAILED — the choice stopped at the mark (wanted \(hex(well)), tool kept \(hex(tool)))")

        // A dot is the same act and has to take the same road.
        let (presetMark, presetTool) = controller.previewInk(dot, onSelectedMark: true)
        print("ink: a dot in hand became \(hex(presetMark)), the tool remembers \(hex(presetTool))")
        print(isSame(presetMark, dot) && isSame(presetTool, dot)
              ? "ink: a dot takes the same road as the well"
              : "ink: FAILED — a dot and the well disagree (wanted \(hex(dot)), tool kept \(hex(presetTool)))")
    }

    /// Whether the editor opens under the line rather than in the middle of the
    /// screen.
    ///
    /// The one part of the layout that is about the screen rather than about the
    /// window, so a screenshot cannot show it and the arithmetic has to be asked
    /// directly. Nothing is opened or moved: the drill reads the frame the
    /// window would be given and compares it with the strip.
    private static func placementDrill(_ controller: EditorWindowController) {
        guard let frame = controller.previewUnderTheLineFrame else {
            print("place: no screen to place it on")
            return
        }
        let visible = (LinePanel.screenUnderPointer() ?? NSScreen.main)?.visibleFrame ?? .zero
        let strip = LinePanel.current?.frame.minY ?? (visible.maxY - Layout.clipboardDepth)
        let source = LinePanel.current == nil ? " (no panel on screen — the depth it would be)" : ""
        print("place: strip ends at \(Int(strip))\(source), screen bottom at \(Int(visible.minY)); "
              + "window \(Int(frame.minX)),\(Int(frame.minY)) "
              + "\(Int(frame.width))×\(Int(frame.height))")
        print(frame.maxY <= strip + 0.5 && frame.minY >= visible.minY - 0.5
              ? "place: the window opens under the strip and on the screen"
              : "place: FAILED — the window is not under the strip")
    }

    /// Anything reaching past the window is a control the user cannot reach.
    /// Printed rather than thrown: a slightly wide row is a design problem, not
    /// a reason to refuse to render.
    ///
    /// Hidden views are skipped. A stack view that has been told a control is
    /// not visible keeps it in the hierarchy with the frame it last had, and
    /// that frame is often parked outside the ground — reporting those would
    /// bury the one line that matters under controls nobody can see anyway.
    private static func reportFitting(_ root: NSView) {
        var overflow: [String] = []
        func walk(_ v: NSView, depth: Int) {
            guard !v.isHiddenOrHasHiddenAncestor else { return }
            let frame = v.convert(v.bounds, to: root)
            if frame.maxX > root.bounds.width + 0.5 || frame.minX < -0.5 {
                overflow.append("  depth \(depth): \(type(of: v)) \(frame)")
            }
            for sub in v.subviews { walk(sub, depth: depth + 1) }
        }
        walk(root, depth: 0)
        print(overflow.isEmpty ? "preview: everything fits" : "preview: outside the window\n\(overflow.joined(separator: "\n"))")
    }
}
