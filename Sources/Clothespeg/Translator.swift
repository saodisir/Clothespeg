import AppKit
import SwiftUI
import Translation

/// Why the engine would not translate.
///
/// Two of its answers are not failures, and they are worth a type of their own:
/// `TranslationError.nothingToTranslate` comes back for words already in the
/// language asked for, and an unsupported pair is a fact about the system
/// rather than about the words. Reporting either as "could not translate" would
/// be telling the person their page is broken.
enum TranslationRefusal: Error {
    case alreadyInThisLanguage
    /// The engine will not translate this pair at all — a language it does not
    /// have, or two it cannot move between.
    case unsupportedPair
}

/// Translation, through the engine the system already has.
///
/// The system's own translator is the only one this app can honestly offer:
/// it runs on the machine, needs no account, no key and no network once the
/// language pair is installed, and the text never leaves the Mac — the same
/// reason the capture is done by this app rather than by a service.
///
/// The awkward part is the door. `TranslationSession` has no public
/// initialiser on macOS 15 through 25; the only way in is SwiftUI's
/// `.translationTask` modifier, which hands a session to a view when that view
/// appears. So a one-point view has to exist somewhere for the life of the
/// app, and this class keeps it. (macOS 26 added
/// `TranslationSession(installedSource:target:)`, which needs none of this —
/// but only for a pair that is already installed, so the modifier is still the
/// only way to get one that is not.)
///
/// All of it is behind `@available(macOS 15, *)`: the app runs on 14, where
/// none of this exists, and the caller has to decide what to say instead.
@available(macOS 15.0, *)
@MainActor
final class Translator {
    static let shared = Translator()

    /// Where the one-point view lives. Kept for the app's lifetime: a session
    /// outlives the request that made it, and a view that went away would take
    /// the cached pair with it.
    private var window: NSWindow?
    private var host: NSHostingView<Bridge>?
    /// The pair whose session has already been handed over, so a second
    /// translation in the same direction does not build a second view.
    private var served: (Locale.Language?, Locale.Language?, TranslationSession)?
    /// At most one request is in flight at a time. The capture asks once, for
    /// one block of text — two at once would need a queue and have no caller.
    private var waiting: CheckedContinuation<TranslationSession, Never>?
    private var pair: (Locale.Language?, Locale.Language?)?
    /// How many times this pair has been asked for. Bumped so a second ask is
    /// a *changed* configuration: the modifier only re-runs when the value it
    /// was given differs.
    private var attempts = 0

    /// The view that exists only to be given a session.
    private struct Bridge: View {
        let configuration: TranslationSession.Configuration?
        let arrived: @Sendable (TranslationSession) async -> Void

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(configuration) { session in
                    await arrived(session)
                }
        }
    }

    // MARK: Asking

    /// Whether a pair can be translated here, and whether it needs downloading
    /// first. Asked before anything is offered, so a missing pair is said out
    /// loud rather than discovered as "翻译没有反应".
    func status(from source: Locale.Language, to target: Locale.Language?) async
        -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    /// The words, in the other language.
    ///
    /// A pair that is supported but not downloaded is handled here rather than
    /// by the caller, because the failure is not an error a caller could act
    /// on: `translate` does not fail on a missing pack, it *waits* — for ever,
    /// if nothing ever asks for one. `prepareTranslation` is the asking, and it
    /// puts a system sheet on this class's window, which is why the window has
    /// to be stood up first.
    ///
    /// The pair is measured *before* the session is asked, and an unsupported
    /// one is refused here. That is the difference between a capture that says
    /// 翻译中… for a second and one that says it for ever: nothing below this
    /// line waits on an answer the engine has no intention of giving.
    func translate(_ text: String, from source: Locale.Language?,
                   to target: Locale.Language?) async throws -> String {
        // A source of nil is left for the engine to work out, which is the one
        // case that can still make it put up its own "which language?" sheet.
        // Callers are expected to know — see `SourceLanguage.guess`.
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let source {
            status = await availability.status(from: source, to: target)
        } else {
            status = (try? await availability.status(for: text, to: target)) ?? .supported
        }
        guard status != .unsupported else { throw TranslationRefusal.unsupportedPair }

        let session = await session(from: source, to: target)
        if status != .installed {
            showHostWindow()
            try await session.prepareTranslation()
            parkHostWindow()
        }
        do {
            return try await session.translate(text).targetText
        } catch {
            // The engine has one answer that is not bad news: `nothingToTranslate`
            // means the words are already in the language that was asked for. It
            // arrives as an error because there is nothing to hand back, and the
            // caller has to be able to tell it apart from a real refusal.
            if case TranslationError.nothingToTranslate = error {
                throw TranslationRefusal.alreadyInThisLanguage
            }
            throw error
        }
    }

    func session(from source: Locale.Language?,
                 to target: Locale.Language?) async -> TranslationSession {
        if let served, served.0 == source, served.1 == target { return served.2 }
        pair = (source, target)
        return await withCheckedContinuation { continuation in
            waiting = continuation
            present()
        }
    }

    /// Asks again for the same pair.
    ///
    /// For the case where the first ask went nowhere: a pair that is supported
    /// but not downloaded has to be agreed to, and the sheet that asks needs a
    /// window it can be seen on. Making that window visible is not a change to
    /// the configuration, so the modifier would not re-run by itself.
    func askAgain() {
        guard pair != nil, served == nil else { return }
        present()
    }

    // MARK: The view

    /// Stands the window in the middle of the screen, so the system's
    /// language-pack sheet has somewhere to appear.
    ///
    /// A sheet on a transparent point in the corner is a question nobody can
    /// see, let alone answer — and an unanswered one blocks the session for
    /// ever, which would look exactly like "翻译坏了".
    func showHostWindow() {
        guard let window else { return }
        window.ignoresMouseEvents = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.level = .floating
        window.setContentSize(NSSize(width: 360, height: 160))
        if let screen = NSScreen.main {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: (screen.frame.midX - frame.width / 2).rounded(),
                                          y: (screen.frame.midY - frame.height / 2).rounded()))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Puts the window back in the corner once there is nothing left to ask.
    ///
    /// A blank white rectangle that stays on screen for the rest of the session
    /// would be the most visible thing this feature ever produced. Parked is
    /// also the state the session came from, so a translation after a download
    /// costs nothing extra — the probe checks that it really does.
    func parkHostWindow() {
        guard let window else { return }
        window.orderOut(nil)
        window.setContentSize(NSSize(width: 1, height: 1))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        window.orderFrontRegardless()
    }

    private func present() {
        let configuration = makeConfiguration()
        let bridge = Bridge(configuration: configuration) { [weak self] session in
            await MainActor.run {
                guard let self, let waiting = self.waiting else { return }
                self.waiting = nil
                self.served = (session.sourceLanguage, session.targetLanguage, session)
                waiting.resume(returning: session)
            }
        }
        if let host {
            host.rootView = bridge
            return
        }
        let host = NSHostingView(rootView: bridge)
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        // Borderless cannot become key, so putting it on the screen does not
        // take the front from whoever has it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Parked in the corner rather than hidden: a view in a window that was
        // never put on the screen does not appear, and a view that has not
        // appeared is a view that is never handed a session. One transparent
        // point at the bottom-left of the main screen is invisible in practice.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        window.orderFrontRegardless()
        self.host = host
        self.window = window
    }

    private func makeConfiguration() -> TranslationSession.Configuration {
        var configuration = TranslationSession.Configuration(source: pair?.0, target: pair?.1)
        attempts += 1
        if attempts > 1 { configuration.invalidate() }
        return configuration
    }
}

// MARK: - Probe

/// The three things that cannot be read off the SDK: whether the one-point
/// view is actually handed a session, whether this machine has the pair
/// installed, and how long a translation takes. Run one with
/// `CLOTHESPEG_TRANSLATE_PROBE=<path>`; ordinary runs never set it.
@available(macOS 15.0, *)
enum TranslateProbe {
    @MainActor
    static func run() -> String {
        let box = Report()
        Task { @MainActor in
            let availability = LanguageAvailability()
            var installed = false
            for (name, from, to) in pairs {
                let status = await availability.status(from: from, to: to)
                box.lines.append("\(name): \(describe(status))")
                if name.hasPrefix("en →"), status == .installed { installed = true }
            }
            let started = Date()
            let session = await Translator.shared.session(from: pairs[0].1, to: pairs[0].2)
            box.sessionArrived = true
            box.lines.append("session arrived after \(Int(Date().timeIntervalSince(started) * 1000)) ms"
                + " (source \(session.sourceLanguage?.maximalIdentifier ?? "nil"),"
                + " target \(session.targetLanguage?.maximalIdentifier ?? "nil"))")
            // Not installed: `translate` does not fail, it *waits* — for ever,
            // if nothing asks for the pack. This is the call that asks.
            if !installed {
                box.lines.append("not installed — asking the system for the pack")
                do {
                    try await session.prepareTranslation()
                    box.lines.append("pack ready")
                } catch {
                    box.lines.append("prepare failed: \(error.localizedDescription)")
                }
            }
            do {
                let began = Date()
                let text = try await session.translate(
                    "The line is a place where things rest, not a place where they pile up. "
                    + "A card you copied a week ago is still where you hung it.")
                box.lines.append("translated in \(Int(Date().timeIntervalSince(began) * 1000)) ms: "
                    + text.targetText)
                let again = Date()
                _ = try await session.translate("A second sentence, same pair.")
                box.lines.append("second sentence in \(Int(Date().timeIntervalSince(again) * 1000)) ms")

                // The download path leaves the window parked behind it. Asking
                // again has to survive that: a session that died with the
                // window would make the first translation work and every one
                // after it hang, with nothing on screen to explain either.
                Translator.shared.showHostWindow()
                box.lines.append("window stood up")
                Translator.shared.parkHostWindow()
                box.lines.append("window parked")
                let after = Date()
                let next = try await session.translate("A third, after the window moved twice.")
                box.lines.append("after parking \(Int(Date().timeIntervalSince(after) * 1000)) ms: "
                    + next.targetText)
            } catch {
                box.lines.append("translate failed: \(error.localizedDescription)")
            }
            box.done = true
        }

        // Phase one: the parked window. The session comes back in
        // milliseconds there, so the asking is not the interesting part —
        // whether the *download* prompt can be answered is.
        pump(seconds: 6) { box.done }
        if !box.done {
            box.lines.append("translate is waiting on something — standing the window up")
            Translator.shared.showHostWindow()
            pump(seconds: 25) { box.done }
        }
        if !box.done { box.lines.append("no answer in 30 s") }
        return "translate probe:\n" + box.lines.joined(separator: "\n")
    }

    private static let pairs: [(String, Locale.Language, Locale.Language)] = [
        ("en → zh-Hans", Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans")),
        ("zh-Hans → en", Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")),
    ]

    /// The part of the probe a self-test can afford: can a session be got at
    /// all, and is the pair in question installed here.
    ///
    /// It deliberately never calls `translate`. A pair that is supported but
    /// not downloaded makes that call *wait* — not fail — and a self-test that
    /// waits is a self-test that hangs at the exact moment somebody needed it.
    @MainActor
    static func line() -> String {
        let box = Report()
        Task { @MainActor in
            let availability = LanguageAvailability()
            var parts: [String] = []
            for (name, from, to) in pairs {
                parts.append("\(name) \(describe(await availability.status(from: from, to: to)))")
            }
            let started = Date()
            let session = await Translator.shared.session(from: pairs[0].1, to: pairs[0].2)
            let took = Int(Date().timeIntervalSince(started) * 1000)
            box.lines.append("session \(took) ms ok ("
                + "\(session.sourceLanguage?.maximalIdentifier ?? "nil") → "
                + "\(session.targetLanguage?.maximalIdentifier ?? "nil")), "
                + parts.joined(separator: ", "))
            box.done = true
        }
        pump(seconds: 8) { box.done }
        return "translate: "
            + (box.done ? box.lines.joined() : "NO SESSION — the SwiftUI bridge is broken")
    }

    /// Turns the run loop, because the session arrives from SwiftUI and
    /// SwiftUI answers on the run loop — never on a thread this could wait on.
    static func pump(seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func describe(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return "installed"
        case .supported: return "supported (needs a download)"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    /// Written from a task, read after the run loop has been pumped.
    private final class Report: @unchecked Sendable {
        var lines: [String] = []
        var done = false
        /// Only proves the session came back, not that the translation did.
        var sessionArrived = false
    }
}
