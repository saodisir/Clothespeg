import AppKit
import Carbon

/// The capture, from the shortcut to the card.
///
/// One object, one gesture at a time. Entering is not re-entrant: a second
/// press while the overlay is up is a person pressing again because nothing
/// seemed to happen, and opening a second overlay on top of the first would
/// answer that by making it worse.
///
/// Where the picture goes is the whole design of this feature, and it is worth
/// saying plainly: it goes to the pasteboard first, so ⌘V works at once, and it
/// hangs on the line second, so it is findable tomorrow. Nothing is asked of
/// the user in between — no menu, no confirmation, no window. Editing is not a
/// decision to make at capture time; it is a decision made later, by opening
/// the card that is already there.
@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private init() {}

    /// The overlay and what it is showing. Nil whenever no capture is running.
    private var window: CaptureOverlayWindow?
    private var surface: CaptureSurface?
    private var screen: NSScreen?
    private var backdrop: CGImage?
    /// The app that was in front when the capture began, so the front can be
    /// given back afterwards.
    ///
    /// This matters more than it looks: the paste after a capture goes to
    /// whatever is frontmost, and a capture that left Clothespeg frontmost
    /// would mean ⌘V did nothing at all. The whole point of copying the
    /// picture is that the next keystroke can use it.
    private var previousApp: NSRunningApplication?
    /// A backdrop is on its way. Separate from `window != nil` because the
    /// moment between the key and the picture is a moment the user may press
    /// the key again.
    private var starting = false
    /// The keys that have to answer while this app is not the frontmost one.
    ///
    /// Only the long capture needs them. Getting out of a long capture must not
    /// depend on who has the keyboard: see `handOverInput()`.
    private var longKeys: [HotKey] = []
    /// Esc, kept for the life of the capture rather than of long mode.
    private var exitKey: HotKey?
    /// Keeps this app out of App Nap while a long capture runs.
    ///
    /// Handing the front away makes this app a background one, and macOS
    /// responds to that by throttling timers — which here means sampling the
    /// screen every second instead of three times a second, and a stitch with
    /// holes in it. An activity assertion is the documented way to say "this is
    /// still work the person asked for".
    private var longActivity: NSObjectProtocol?
    /// The window laid over the bar during a long capture, which is the only
    /// thing in that mode still able to take a click. See `showDoneBar()`.
    private var doneBar: LongBarPanel?

    // MARK: Entering

    /// A frame waiting to be put back once the overlay exists.
    ///
    /// Only ever set by the one road that starts a capture with something
    /// already in hand: a remembered frame from another display, where the
    /// overlay has to be built first because it is one screen wide.
    private var pendingRestore: CGRect?

    func begin(restoring: CGRect? = nil, on wanted: NSScreen? = nil) {
        guard !starting, window == nil else { return }
        // Asked before anything else, so a refusal is a sentence rather than a
        // dimmed screen that does nothing.
        guard ScreenGrab.ensureAccess() else {
            report(ScreenGrabError.noPermission)
            return
        }
        guard let target = wanted ?? Self.screenUnderPointer() else { return }
        starting = true
        pendingRestore = restoring
        previousApp = NSWorkspace.shared.frontmostApplication
        // Read before the backdrop is taken, and read from the window server
        // rather than from the picture: what a click may take is the windows
        // that exist now. This app's own windows are in the list — the strip and
        // the editor are on the screen like anything else — and only its capture
        // overlay is not, because it does not exist yet.
        let pickable = WindowPick.windows()
        diagLog("Capture: entering on \(target.localizedName), \(pickable.count) window(s) pickable")

        Task {
            do {
                let image = try await ScreenGrab.screenImage(of: target)
                self.starting = false
                self.present(backdrop: image, windows: pickable, on: target)
            } catch {
                self.starting = false
                self.previousApp = nil
                self.report(error)
            }
        }
    }

    private func present(backdrop: CGImage, windows: [PickableWindow], on screen: NSScreen) {
        let surface = CaptureSurface(backdrop: backdrop, screen: screen, windows: windows)
        let window = CaptureOverlayWindow(screen: screen, surface: surface)
        surface.onPick = { [weak self] picked in self?.pick(picked) }
        surface.onFinish = { [weak self] rect in self?.finish(rect) }
        surface.onFinishLong = { [weak self] image in self?.finishLong(image) }
        surface.onReadArea = { [weak self] rect in self?.read(rect) }
        surface.onFinishText = { [weak self] text in self?.finishText(text) }
        surface.onFinishColour = { [weak self] hex in self?.finishColour(hex) }
        surface.onTranslate = { [weak self] text in self?.translate(text) }
        surface.onFinishTranslation = { [weak self] text in self?.finishTranslation(text) }
        surface.onEnterLongMode = { [weak self] in self?.handOverInput() }
        surface.onEdit = { [weak self] target in self?.edit(target) }
        surface.onAgain = { [weak self] in self?.restoreLast() }
        surface.onCancel = { [weak self] in self?.cancel() }
        self.surface = surface
        self.window = window
        self.screen = screen
        self.backdrop = backdrop
        // A frame carried over from the last capture. Put in before the window
        // is shown rather than after, so the first frame it draws already has
        // it — a frame that fades in a moment later is a frame arriving after
        // the hand has started moving.
        if let pending = pendingRestore {
            surface.restore(pending)
            pendingRestore = nil
        }

        // The cursor and the keys both go to the frontmost app, so this one has
        // to be frontmost for the crosshair to be drawn. Esc does not depend on
        // it any more — see `listenForEscape()`.
        listenForEscape()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface)
        surface.beginTracking()
    }

    /// Gives the front — and with it the keyboard — to the app being scrolled.
    ///
    /// A long capture has to let the wheel through to that app, and letting the
    /// mouse through means every click in the content also activates it. The
    /// first version let that happen by accident: the app below became active,
    /// the keyboard went with it, and Return and Esc were typed into the page
    /// while a capture that could not end sat on top of it. The person's report
    /// was exact — "回车无效 esc 退出无效".
    ///
    /// So the front is handed over on purpose and the two keys that end the
    /// capture are registered as Carbon hot keys first. That is the same
    /// division the open-source scroll-capture tools use, and it is better than
    /// fighting to keep the front for a reason that only shows up later:
    /// scrolling then belongs to the app below as its own behaviour, instead of
    /// depending on the system's "scroll inactive windows" setting being on —
    /// a promise this app cannot check and would have been quietly trusting.
    private func handOverInput() {
        if longKeys.isEmpty {
            let ends: [(key: Int, id: UInt32, action: () -> Void)] = [
                (kVK_Return, 92, { [weak self] in self?.surface?.finishLong() }),
                // The keypad's Enter is a different key code, and a capture
                // that ignores it is a capture that ignores half the keyboards
                // that have one.
                (kVK_ANSI_KeypadEnter, 93, { [weak self] in self?.surface?.finishLong() }),
            ]
            for end in ends {
                let key = HotKey(keyCode: end.key, modifiers: 0, id: end.id, action: end.action)
                guard key.registerStatus == noErr else {
                    diagLog("Capture: hot key \(end.key) refused (\(key.registerStatus))")
                    continue
                }
                longKeys.append(key)
            }
        }
        // The mouse's way out, laid over the bar. Made whatever the keys did:
        // it needs no hot key, no permission and no front, so it is the one exit
        // that cannot fail to exist.
        showDoneBar()
        // Without a way out the front is not given away: a capture that cannot
        // be ended is worse than one whose scrolling needed a system setting.
        guard exitKey != nil else {
            diagLog("Capture long: no exit key — keeping the front")
            return
        }
        if longActivity == nil {
            longActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "Long capture: sampling the screen while the front is elsewhere"
            )
        }
        NSApp.deactivate()
        // The button's window is checked after the handover, not before: an app
        // giving up the front is exactly when a panel is most likely to be
        // ordered out from under it, and that would be a button that is drawn
        // but not there.
        diagLog("Capture long: gave the front away — Done still visible "
            + "\(doneBar?.isVisible ?? false)")
    }

    /// Lays the Done button over the bar, so a long capture can be ended by
    /// mouse alone.
    ///
    /// The overlay ignores the mouse for the length of a long capture, so this
    /// is the only road a press has to that button: drawn in the overlay it
    /// would be a picture of a button. Nothing here depends on this app being
    /// front, which is why it is worth having — Return and Esc are keys borrowed
    /// from the page, and a borrowed key should not be the only way out.
    private func showDoneBar() {
        guard doneBar == nil, let surface, let bar = surface.longBarOnScreen else { return }
        let panel = LongBarPanel(capsule: bar.capsule, done: bar.done, close: bar.close)
        panel.onDone = { [weak self] in
            // Logged with the activation state: a press on a nonactivating panel
            // is supposed to leave the page in front, and this is the line that
            // says whether it did.
            diagLog("Capture long: Done pressed (this app active: \(NSApp.isActive))")
            self?.surface?.finishLong()
        }
        panel.onClose = { [weak self] in
            // Leaving with nothing. The picture already stitched is thrown away:
            // this is the way out for someone who changed their mind, and asking
            // them to finish the capture first would be asking them to keep the
            // thing they are abandoning.
            diagLog("Capture long: ✕ pressed (this app active: \(NSApp.isActive))")
            self?.cancel()
        }
        panel.onPointer = { [weak self] point in self?.surface?.setPointerOnBar(point) }
        // `orderFrontRegardless` rather than `orderFront`: this app is not front
        // and is about to stop being front on purpose, and a plain order is
        // allowed to do nothing about that.
        panel.orderFrontRegardless()
        doneBar = panel
        diagLog("Capture long: Done button at \(Int(bar.capsule.minX)),\(Int(bar.capsule.minY)) "
            + "\(Int(bar.capsule.width))×\(Int(bar.capsule.height)), "
            + "level \(panel.level.rawValue), visible \(panel.isVisible), "
            + "number \(panel.windowNumber)")
        // Asked again once the window server has had a chance to answer. Being
        // ordered front and being on screen are different states, and the second
        // one is filled in asynchronously — a panel the system counts as covered
        // is a panel that gets no presses, while still being drawn by the
        // overlay underneath and looking perfectly pressable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let panel = self?.doneBar else { return }
            diagLog("Capture long: Done window settled — visible \(panel.isVisible), "
                + "\(panel.occlusionState.contains(.visible) ? "uncovered" : "COVERED"), "
                + "frame \(Int(panel.frame.minX)),\(Int(panel.frame.minY)) "
                + "\(Int(panel.frame.width))×\(Int(panel.frame.height)), "
                + "app active \(NSApp.isActive), key-can \(panel.canBecomeKey), "
                + "ignoresMouse \(panel.ignoresMouseEvents), alpha \(panel.alphaValue)")
            // Who the window server puts at that pixel. Being visible and being
            // on top are different claims, and a window that is merely visible
            // under something else is a button that can be seen and not pressed.
            let middle = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let hit = panel.contentView?.hitTest(NSPoint(x: panel.frame.width / 2,
                                                         y: panel.frame.height / 2))
            diagLog("Capture long: at the pill — \(Self.topmost(at: middle)), "
                + "our panel is \(panel.windowNumber), "
                + "content \(Int(panel.contentView?.frame.width ?? 0))×"
                + "\(Int(panel.contentView?.frame.height ?? 0)), "
                + "hit \(hit == nil ? "nothing" : "a view")")
        }
    }

    /// The window the system considers frontmost at a screen point, for the log.
    ///
    /// Asked of the window server rather than of AppKit: this is a question about
    /// which window a click would reach, and AppKit's own answer ("my window is
    /// visible") turned out to be compatible with the click going somewhere else
    /// entirely.
    private static func topmost(at point: NSPoint) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return "unreadable window list" }
        // The window server counts down from the top of the main display; this app
        // counts up from the bottom of it.
        let fromTop = (NSScreen.screens.first?.frame.maxY ?? 0) - point.y
        for entry in list {
            guard let box = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  box["X"] != nil else { continue }
            let rect = CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0,
                              width: box["Width"] ?? 0, height: box["Height"] ?? 0)
            guard rect.contains(CGPoint(x: point.x, y: fromTop)) else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            let number = entry[kCGWindowNumber as String] as? Int ?? -1
            return "\(owner) window \(number) at layer \(layer)"
        }
        return "nothing at that point"
    }

    private func hideDoneBar() {
        guard let panel = doneBar else { return }
        doneBar = nil
        panel.orderOut(nil)
        // Held for one turn: this can run from inside that panel's own mouseDown,
        // and a window must outlive the event it is dispatching.
        DispatchQueue.main.async { panel.orderOut(nil) }
    }

    /// Esc, wherever it is pressed and whoever has the keyboard.
    ///
    /// Registered once for the whole capture rather than only for long mode.
    /// The window is normally key and would hear the key by itself — but "the
    /// window is key" is an assumption, the kind that stops being true in some
    /// combination nobody tried, and the cost of not relying on it is one
    /// registration.
    private func listenForEscape() {
        guard exitKey == nil else { return }
        let key = HotKey(keyCode: kVK_Escape, modifiers: 0, id: 90) { [weak self] in self?.escape() }
        guard key.registerStatus == noErr else {
            diagLog("Capture: Escape hot key refused (\(key.registerStatus)) — it will only work while this app is front")
            return
        }
        exitKey = key
    }

    /// The one meaning of Esc, whichever of the two roads it arrives by.
    ///
    /// A panel that is open eats the key that would close it, exactly as it
    /// eats the click that would close it. Two roads in, one decision.
    private func escape() {
        if surface?.dismissPanel() == true { return }
        cancel()
    }

    // MARK: Leaving

    private func finish(_ rect: CGRect, kind: LastCapture.Kind? = nil) {
        guard let backdrop, let screen else { return cancel() }
        // Cropped from the backdrop rather than grabbed again. The backdrop is
        // what the user was looking at while choosing, so this is the only way
        // the picture and the highlight can be the same thing — a second grab
        // a heartbeat later can catch a menu closing or a video advancing.
        let image = Self.crop(backdrop, to: rect, on: screen)
        close()
        guard let image else {
            report(ScreenGrabError.failed(L("That area could not be read back from the screen.")))
            return
        }
        // Remembered here rather than where the drag started: what "again"
        // should mean is the rectangle that became a picture, and a rectangle
        // that failed to become one is not worth going back to.
        LastCapture.remember(kind ?? defaultKind(for: rect, on: screen), rect)
        commit(image, from: nil)
    }

    /// A long capture, which arrives already stitched.
    ///
    /// No crop and no second grab: the picture was assembled from frames taken
    /// while the person scrolled, and the only thing left to do with it is what
    /// is done with every other capture — write it, copy it, hang it.
    private func finishLong(_ image: CGImage) {
        // The rectangle this grew from, not the stitched height: there is no
        // wheel to turn on someone's behalf, so "again" can only mean the frame
        // it started at — decided in `LastCapture.Replay`, said here.
        if let region = surface?.region { LastCapture.remember(.long, region) }
        close()
        commit(image, from: nil)
    }

    /// Reads the words out of an area, and leaves the overlay holding the
    /// question open until they are agreed with.
    ///
    /// Cropped from the backdrop rather than grabbed again, for the reason every
    /// other path here does the same: the backdrop is what the person was looking
    /// at while choosing the area, and a second grab a moment later can catch a
    /// different page.
    ///
    /// The answer goes back to the surface rather than straight onto the line.
    /// This is the one kind of capture where the result is worth checking before
    /// it is kept — a picture of the wrong window is obvious on the card, and a
    /// page of mangled type is not.
    private func read(_ rect: CGRect) {
        guard let backdrop, let screen else {
            surface?.showReading(nil)
            return
        }
        guard let image = Self.crop(backdrop, to: rect, on: screen) else {
            surface?.showReading(nil)
            return
        }
        // Words are a capture too: the area was chosen for what it says, and
        // that stays true after the window is gone.
        LastCapture.remember(.words, rect)
        let surface = surface
        DispatchQueue.global(qos: .userInitiated).async {
            // Vision blocks for a few hundred milliseconds. Off the main thread
            // because the overlay stays up and keeps answering clicks while it
            // runs, and a frozen question is worse than a slow one.
            let text = PictureText.recognize(in: image)
            DispatchQueue.main.async { surface?.showReading(text) }
        }
    }

    /// The words in the other language.
    ///
    /// Two engines, and which one answers is decided by a key rather than by a
    /// switch: with one filled in, `TranslationAPI` translates on the other end
    /// of a wire; with the field empty, the system's own engine does it on this
    /// Mac. See `TranslationAPI` for why the second one exists at all.
    ///
    /// The source language is left for the engine to work out. Knowing which
    /// language a page is in is its job, and a wrong guess on our side would
    /// fail as silence rather than as an error.
    private func translate(_ text: String) {
        let surface = surface
        // The rectangle, not the words: asking the same question of the same
        // area is what repeating this door means. Written before the engine is
        // asked, because what "again" remembers is where the question was put,
        // not how it came back — a refusal is a reason to ask later, not a
        // reason to forget the place.
        if let region = surface?.region { LastCapture.remember(.translate, region) }

        let asked = Self.translationTarget()

        // A filled-in key is the whole of the choice between the two engines,
        // so the remote one is asked first and the system's engine is not
        // asked afterwards: a fallback that ran quietly would hide a wrong key
        // behind a worse translation, and the person would have no way to tell
        // which had happened.
        if TranslationAPI.isConfigured {
            guard let target = asked else {
                surface?.showTranslationRefused(.unsure)
                diagLog("Capture text: no target language for the remote engine")
                return
            }
            // Asked, and already in the language asked for. The model would
            // hand the same words back, which reads as a button that did
            // nothing, and only the guess can tell that from a translation
            // that happens to match. A guess that fails is not a refusal here
            // — the model does not need to know what it is reading.
            if let source = SourceLanguage.guess(text), SourceLanguage.same(source, target) {
                surface?.showTranslationNoop()
                diagLog("Capture text: already \(source.minimalIdentifier)")
                return
            }
            Task { @MainActor in
                do {
                    let translated = try await TranslationAPI.translate(text, into: target)
                    surface?.showTranslation(translated)
                } catch {
                    surface?.showTranslationRefused(.failed)
                    diagLog("Capture text: remote translation failed — \(error.localizedDescription)")
                }
            }
            return
        }

        guard #available(macOS 15.0, *) else {
            surface?.showTranslation(nil)
            diagLog("Capture text: no translation on this macOS (needs 15)")
            return
        }
        // Worked out here and handed over, never left to the engine. Given no
        // source the engine may answer with a sheet of its own —「无法自动检测
        // 语言。请选择要翻译的语言。」— and a sheet nobody answers is a capture
        // that says 翻译中… for ever. That is the report this closes.
        guard let source = SourceLanguage.guess(text) else {
            surface?.showTranslationRefused(.unsure)
            diagLog("Capture text: cannot tell which language \(text.count) character(s) are in")
            return
        }
        let target = asked
        // Already in the language asked for. Asking would be a round trip to be
        // told what is known, and the engine's way of saying it is an error.
        if SourceLanguage.same(source, target) {
            surface?.showTranslationNoop()
            diagLog("Capture text: already \(source.minimalIdentifier)")
            return
        }
        Task { @MainActor in
            do {
                let translated = try await Translator.shared.translate(text, from: source, to: target)
                surface?.showTranslation(translated)
            } catch TranslationRefusal.alreadyInThisLanguage {
                // Not a failure, and said as its own thing: the words are
                // already in the target language, so the answer is the words.
                surface?.showTranslationNoop()
            } catch TranslationRefusal.unsupportedPair {
                surface?.showTranslationRefused(.unsupported)
                diagLog("Capture text: no pair \(source.minimalIdentifier) → "
                    + "\(target?.minimalIdentifier ?? "system")")
            } catch {
                surface?.showTranslation(nil)
                diagLog("Capture text: translation failed — \(error.localizedDescription)")
            }
        }
    }

    /// Where a translation should land.
    ///
    /// Read from the shortlist the person configured and the one they left in
    /// force, both of which are language codes now rather than four named
    /// cases — the bar's menu offers ten languages, and an enum of four could
    /// not have held them.
    ///
    /// It has to be a setting and not a guess: a Chinese page on a Chinese Mac
    /// wanting English is the ordinary case for anyone who reads both, and no
    /// default can tell it from someone who does not.
    private static func translationTarget() -> Locale.Language? {
        Locale.Language(identifier: TranslationTargets.current)
    }

    /// The words, on their way to the line as text rather than as a picture.
    ///
    /// The same landing as a capture minus the file: nothing is written, nothing
    /// is named, and the card that appears is a snippet. The pasteboard is filled
    /// first for the same reason it is for a picture — pasting is most of why
    /// anyone asked — and marked as this app's own write so the watcher does not
    /// hang a second card of the same words.
    private func finishText(_ text: String) {
        // The pasteboard before the window: closing hands the front back to the
        // app underneath, and a copy that lands in the middle of a focus change
        // is a copy with something happening on either side of it.
        Self.put(text, on: NSPasteboard.general)
        close()
        (NSApp.delegate as? AppDelegate)?.acceptCapturedText(text)
        diagLog("Capture text: \(text.count) character(s) on the line")
    }

    /// The colour, taken away — and nothing kept. The same landing as the
    /// words: the pasteboard first, one text card, and no picture or file.
    /// Marked as this app's own write, so the watcher does not hang a second
    /// card of the same value.
    private func finishColour(_ hex: String) {
        Self.put(hex, on: NSPasteboard.general)
        close()
        (NSApp.delegate as? AppDelegate)?.acceptCapturedText(hex)
        diagLog("Capture colour: \(hex) on the line")
    }

    /// The translation, taken away — and nothing kept.
    ///
    /// The translate door promised the words in the other language, on the
    /// screen, and nothing on the line: it is for reading a page for a moment,
    /// not for collecting it. The words still go to the pasteboard, because
    /// pasting them somewhere is what comes next most of the time, and a
    /// translation that dies with the window has to be produced twice.
    private func finishTranslation(_ text: String) {
        Self.put(text, on: NSPasteboard.general)
        close()
        // A card as well as the pasteboard, and this is the fix for "the copy
        // button does nothing": the copy always reached the pasteboard — the
        // log line below has said so since it was written — but nothing on
        // screen said so. The line's clipboard deck is this app's window onto
        // the pasteboard, and a copy that is in the pasteboard and not in the
        // deck reads as a copy that never happened. Marked as our own write
        // above, so the watcher does not hang a second card of the same words.
        (NSApp.delegate as? AppDelegate)?.acceptCapturedText(text)
        // Read back rather than assumed. "The copy button does nothing" and
        // "the copy never reached the pasteboard" are the same report from the
        // outside, and only one of them is this app's fault.
        let landed = NSPasteboard.general.string(forType: .string)
        diagLog("Capture text: translation of \(text.count) character(s) copied"
            + ", pasteboard holds \(landed?.count ?? -1) character(s)"
            + (landed == text ? "" : " — NOT what was handed over"))
    }

    /// Puts words on the pasteboard, marked as this app's own write.
    ///
    /// The mark is what stops the watcher hanging a second card of the same
    /// words. Shared by the two ways text leaves a capture because the mark is
    /// not optional: a copy that forgot it looks exactly like a copy made in
    /// another app, and the card appears twice.
    static func put(_ text: String, on pasteboard: NSPasteboard) {
        let entry = NSPasteboardItem()
        entry.setString(text, forType: .string)
        entry.setString("1", forType: ClipboardWatcher.ourWrite)
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])
    }

    /// A window, photographed on its own.
    ///
    /// The one path that grabs again instead of cropping, and the reason is the
    /// reason to offer window capture at all: a window half covered by another
    /// comes out whole only when it is rendered from its own surface.
    private func pick(_ picked: PickableWindow) {
        // Where it was, as well as which one it was: the id is what makes the
        // repeat photograph the window rather than whatever is in front of it,
        // and the frame is what the id is replaced by when that window is gone.
        LastCapture.remember(.window, picked.frame, window: picked.id)
        if picked.isOwn { return takeOwnWindow(picked, editAfter: false) }
        // Closed first, and deliberately: the overlay is a full-screen window
        // at the top level, and it must not be part of the answer even for the
        // instant before the frame is taken.
        close()
        diagLog("Capture: window \(picked.id) of \(picked.owner)")
        Task {
            do {
                let image = try await ScreenGrab.windowImage(id: picked.id)
                self.commit(image, from: picked.owner.isEmpty ? nil : picked.owner)
            } catch {
                self.report(error)
            }
        }
    }

    /// One of our own windows, cut out of the backdrop instead of rendered.
    ///
    /// It is already in the backdrop — that is what the change to `ScreenGrab`
    /// bought — and that copy is the honest one: it is the window as it was on
    /// the screen when the frame was drawn, in the same instant as everything
    /// around it. A window render would answer a different question (`what does
    /// this window look like on its own`) and it is the one path here that has
    /// never been proved to work on a window belonging to the app doing the
    /// asking. The trade is a window we own that was half covered coming out
    /// half covered — which is what the screen showed, and the reason window
    /// capture exists at all is somebody else's window behind somebody else's.
    private func takeOwnWindow(_ picked: PickableWindow, editAfter: Bool) {
        guard let backdrop, let screen else { return cancel() }
        let image = Self.crop(backdrop, to: picked.frame, on: screen)
        close()
        diagLog("Capture: own window \(picked.id) cut from the backdrop")
        guard let image else {
            report(ScreenGrabError.failed(L("That area could not be read back from the screen.")))
            return
        }
        commit(image, from: picked.owner.isEmpty ? nil : picked.owner, editAfter: editAfter)
    }

    /// The chosen thing, taken and then opened in the editor.
    ///
    /// The same landing as every other capture — file, pasteboard, card — and
    /// the editor opens on that very file. In that order on purpose: the
    /// picture is already on the pasteboard and already hanging on the line by
    /// the time the editor appears, so closing it without saving loses nothing,
    /// and the card follows the edits when it does save (`Markup.shared.onSaved`
    /// reloads the thumbnail). Two artefacts would be the alternative — the shot
    /// as it was, and the shot as it became — and nobody asked for the first.
    private func edit(_ target: CaptureTarget) {
        switch target {
        case .region(let rect):
            guard let backdrop, let screen else { return cancel() }
            // Cropped from the backdrop, like `finish`: the frame on screen and
            // the picture are then the same instant.
            let image = Self.crop(backdrop, to: rect, on: screen)
            close()
            guard let image else {
                report(ScreenGrabError.failed(L("That area could not be read back from the screen.")))
                return
            }
            LastCapture.remember(defaultKind(for: rect, on: screen), rect)
            commit(image, from: nil, editAfter: true)
        case .window(let picked):
            LastCapture.remember(.window, picked.frame, window: picked.id)
            if picked.isOwn { return takeOwnWindow(picked, editAfter: true) }
            close()
            Task {
                do {
                    let image = try await ScreenGrab.windowImage(id: picked.id)
                    self.commit(image, from: nil, editAfter: true)
                } catch {
                    self.report(error)
                }
            }
        }
    }

    /// What a rectangle was, when the caller did not say.
    ///
    /// The whole screen is the one case worth telling apart: it is the only
    /// rectangle that fills the display exactly, and a log line reading
    /// `area 1710×1107` about a Space press answers the wrong question.
    private func defaultKind(for rect: CGRect, on screen: NSScreen) -> LastCapture.Kind {
        rect == screen.frame ? .screen : .area
    }

    func cancel() {
        diagLog("Capture: cancelled")
        close()
    }

    // MARK: Again

    /// The last frame, put back on the screen — not taken again by itself.
    ///
    /// The first draft fired the shutter on the press: the same rectangle, a
    /// picture, done. Living with it for ten minutes was enough to see why that
    /// is the wrong verb — the case this exists for is a page that has *moved*,
    /// and a button that photographs a stale rectangle without showing it to
    /// anyone is a button that takes the wrong picture confidently. So the
    /// frame comes back where it was, with its handles, and the person decides:
    /// double-click or Return takes it, dragging adjusts it, clicking a window
    /// or a door in the bar says something else entirely.
    ///
    /// Which also means the type is not replayed. `LastCapture.kind` is still
    /// recorded and still logged — it is one field and it says what the frame
    /// was for — but it does not choose anything on the person's behalf. A door
    /// is one press away (`T` re-reads the frame that is already drawn) and that
    /// press is theirs to make.
    private func restoreLast() {
        guard let last = LastCapture.stored else { return }
        let rect = last.rect
        diagLog("Capture again: \(last.kind.rawValue) "
            + "\(Int(rect.width))×\(Int(rect.height))"
            + " at \(Int(rect.minX)),\(Int(rect.minY))")
        // The same display: the frame goes back into the overlay that is
        // already up. No second grab and no flash — and the backdrop it will
        // be cut from is the very one a hand-drawn frame would have been cut
        // from, so restoring costs nothing in accuracy.
        if let screen, screen.frame.intersects(rect), let surface {
            surface.restore(rect)
            return
        }
        // A frame from another display. This overlay is one screen wide, so the
        // capture has to start again over there, with the frame already in hand.
        close()
        begin(restoring: rect, on: Self.screen(for: rect))
    }

    /// The screen a remembered rectangle belongs to.
    ///
    /// By geometry rather than by a stored display id, because the rectangle is
    /// the thing being replayed and a display that has been rearranged since has
    /// moved the pixels rather than invalidated them. A rectangle that belongs
    /// to no screen now — the display it was cut from is gone — falls back to
    /// the one under the pointer, where `areaImage` clips it and says so if
    /// nothing is left.
    private static func screen(for rect: CGRect) -> NSScreen? {
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(middle) } ?? screenUnderPointer()
    }

    private func close() {
        // The button's window goes first. It is the only window of this capture
        // a click can still reach, and it must stop being reachable before the
        // picture exists.
        hideDoneBar()
        surface?.endTracking()
        // Let go of the keys before anything else: they belong to the whole
        // keyboard for as long as they exist, and a Return that outlives the
        // capture is a Return the next app never sees.
        longKeys.removeAll()
        exitKey = nil
        if let longActivity {
            ProcessInfo.processInfo.endActivity(longActivity)
        }
        longActivity = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        surface = nil
        screen = nil
        backdrop = nil
        // The front goes back where it came from. Done after the window is gone
        // rather than before, or this app would be asked to activate itself
        // again by its own remaining window.
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: Landing

    /// Writes the picture, copies it, hangs it — and optionally opens it.
    ///
    /// `editAfter` is the 编辑 door and nothing else: the landing is the same
    /// as any capture, then the editor opens on the very file that landed. In
    /// that order on purpose, so that closing the editor without saving still
    /// leaves a picture on the pasteboard and a card on the line. The editor is
    /// asked for at the end, once the card exists, because it looks the file up
    /// by URL and a card that arrived while the window was being built would be
    /// a card the editor's thumbnail never hears about.
    private func commit(_ image: CGImage, from app: String?, editAfter: Bool = false) {
        Inbox.prepare()
        let url = Inbox.folder.appendingPathComponent(Self.fileName())
        guard let data = Self.pngData(image) else {
            report(ScreenGrabError.failed(L("The picture could not be encoded.")))
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            report(error)
            return
        }
        // Stamped the way macOS stamps its own captures, so this file is
        // recognisable as a capture to anything that asks — including this
        // app's own sweep, which would otherwise leave it in the folder for
        // ever because nothing claims it.
        Inbox.markAsScreenCapture(url)

        // The pasteboard first, and the card second: pasting is the reason most
        // captures were taken, and it should not wait on a file read.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setData(data, forType: .png)
        entry.setString(url.absoluteString, forType: .fileURL)
        // Marked as this app's own write, the same way a copy from a card is:
        // without it the watcher would hang a second card of the same picture.
        entry.setString("1", forType: ClipboardWatcher.ourWrite)
        pasteboard.writeObjects([entry])

        (NSApp.delegate as? AppDelegate)?.acceptCapture(at: url, from: app)
        diagLog("Capture: \(image.width)×\(image.height) → \(url.lastPathComponent)")
        if editAfter {
            // Deferred, because this is being called from inside the click the
            // overlay is still dispatching, and the editor takes the front.
            // Bringing a window forward in the middle of another window's event
            // is how a click ends up delivered to the window that just appeared.
            DispatchQueue.main.async {
                ImageEditor.shared.open(url)
                diagLog("Capture: editor opened on \(url.lastPathComponent)")
            }
        }
    }

    // MARK: Plumbing

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// The backdrop, cut down to a screen rectangle.
    ///
    /// Three coordinate systems meet here and only one of them is obvious: the
    /// rectangle is AppKit's (y up, from the screen's bottom left), the image is
    /// measured in pixels (y down, from its top left), and the two are related
    /// by the display's scale factor rather than by a constant.
    ///
    /// `nonisolated` because it is arithmetic: the self-test runs it off the
    /// main actor, and a crop that had to hop back to the main thread would be
    /// a crop with a queue in front of it.
    nonisolated static func crop(_ image: CGImage, to rect: CGRect, on screen: NSScreen) -> CGImage? {
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let scale = CGFloat(image.width) / frame.width
        let local = CGRect(x: rect.minX - frame.minX,
                           y: rect.minY - frame.minY,
                           width: rect.width,
                           height: rect.height)
        let pixels = CGRect(x: (local.minX * scale).rounded(),
                            y: (CGFloat(image.height) - local.maxY * scale).rounded(),
                            width: (local.width * scale).rounded(),
                            height: (local.height * scale).rounded())
        let clipped = pixels.intersection(CGRect(x: 0, y: 0,
                                                 width: image.width, height: image.height))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return image.cropping(to: clipped)
    }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        // The rep is told the size in points the pixels stand for, so the PNG
        // carries the display's resolution: without it a 2× grab opens at twice
        // the size it was on screen, which is a picture that looks wrong even
        // though every pixel in it is right.
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// `Screenshot 2026-11-02 at 19.20.31.png`, the shape macOS itself uses.
    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date())).png"
    }

    private func report(_ error: Error) {
        diagLog("Capture failed: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = L("The screen could not be captured")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
