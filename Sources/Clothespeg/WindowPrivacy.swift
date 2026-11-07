import AppKit
import CoreGraphics
import ImageIO

/// The four windows that carry the words being read rather than the picture
/// being made. Their names live in one place — `isPrivate` below — because a
/// window that opens later has to be judged by the same list as the ones
/// already on screen.

/// Whether the reading side of the app is left out of pictures of the screen.
///
/// `NSWindow.sharingType = .none` is a documented, per-window request to the
/// compositor: the window is still painted for the person at the Mac, but is
/// not drawn into frames handed to screen capture, recording or sharing. It is
/// not a detection of recording, and it cannot be: a screenshot is a single
/// instant with no warning, and macOS gives no reliable "somebody is
/// recording" signal. So the answer is a plain switch, on until it is off.
enum WindowPrivacy {
    static let defaultsKey = "hideFromScreenCapture"

    /// What a window is before this switch has ever been touched. Read from a
    /// fresh window rather than written down: restoring a guessed default on a
    /// macOS that changed it would leave the line invisible in every capture
    /// long after somebody turned the switch back off.
    static let normal: NSWindow.SharingType =
        NSWindow(contentRect: .zero, styleMask: .borderless,
                 backing: .buffered, defer: false).sharingType

    /// Where the user put the switch, whether or not it can take effect.
    /// The settings page binds this — binding `isHidden` instead would make
    /// the toggle spring back while the extras are locked.
    static var isWanted: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// The answer that actually reaches the compositor: the switch is on
    /// **and** the small-features tip has been redeemed. Asked afresh each
    /// time rather than cached, so a code entered after a window was made
    /// cannot leave that window behind.
    static var isHidden: Bool {
        isWanted && SmallFeaturesLicense.isUnlocked()
    }

    /// The only place the answer changes. Same-value writes stop here, so a
    /// page echoing the announcement cannot start a loop.
    static func set(_ on: Bool) {
        guard on != isWanted else { return }
        UserDefaults.standard.set(on, forKey: defaultsKey)
        applyToAll()
        SettingsAnswers.announce(defaultsKey)
    }

    /// Which windows the switch is about. The capture overlay, the picture
    /// editor, the translation card and the settings window are deliberately
    /// not here: they are the tool being shown, not the words being read.
    private static func isPrivate(_ window: NSWindow) -> Bool {
        window is LinePanel || window is NoteWindow
            || window is ZoomWindow || window is SearchWindow
    }

    static func apply(to window: NSWindow) {
        guard isPrivate(window) else { return }
        window.sharingType = isHidden ? .none : normal
    }

    /// Windows made before the switch moved. Windows made after it read the
    /// answer in their own `init`, which is why both halves are needed.
    static func applyToAll() {
        for window in NSApplication.shared.windows { apply(to: window) }
    }
}

/// Counting two flat colours in a captured frame. No AppKit here, so a
/// detached task can do it.
///
/// The bytes are read through an explicit sRGB context rather than
/// `NSBitmapImageRep.colorAt`, which answers a different colour for a
/// saturated blue and would turn this check into a guess.
enum PrivacyPixels {
    /// Green is the ordinary window, magenta the one marked `.none`.
    static func tally(_ image: CGImage) -> (visible: Int, hidden: Int) {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return (0, 0) }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return (0, 0) }

        var visible = 0, hidden = 0
        var i = 0
        while i + 3 < bytes.count {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            if r < 45, g > 210, b < 45 { visible += 1 }
            if r > 210, g < 45, b > 210 { hidden += 1 }
            i += 4
        }
        return (visible, hidden)
    }

    /// A captured frame says the window is hidden only when it also says the
    /// ordinary one arrived. Otherwise "no magenta" is what a failed capture
    /// looks like too.
    static func verdict(_ tally: (visible: Int, hidden: Int)?) -> String {
        guard let tally else { return "NOT CAPTURED" }
        guard tally.visible > 1000 else { return "NOT CAPTURED (green \(tally.visible) px)" }
        return tally.hidden <= 50 ? "hidden" : "VISIBLE (magenta \(tally.hidden) px)"
    }
}

/// Whether this macOS actually honours `sharingType = .none`.
///
/// Reading the headers is not enough: the answer has changed between macOS
/// releases, and an app that promises a private teleprompter on a system that
/// still records it is worse than one with no switch at all. Two flat windows,
/// one ordinary and one marked private, and three ways of capturing the screen
/// are counted in pixels. Run with `CLOTHESPEG_PRIVACY_PROBE=<path>`.
enum PrivacyProbe {
    private final class FlatView: NSView {
        let colour: NSColor
        init(colour: NSColor) {
            self.colour = colour
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func draw(_ dirtyRect: NSRect) {
            colour.setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }

    private static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    private static let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    private static func make(_ colour: NSColor, at rect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = colour
        window.hasShadow = false
        window.level = .statusBar
        window.hidesOnDeactivate = false
        window.contentView = FlatView(colour: colour)
        return window
    }

    private static func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private final class Box {
        var kit: (visible: Int, hidden: Int)?
        var kitError = ""
    }

    /// `screencapture` writes one file per display, so all of them are read.
    private static func systemShot() -> (visible: Int, hidden: Int)? {
        let prefix = "/tmp/clothespeg-privacy-shot"
        if let old = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
            for name in old where name.hasPrefix("clothespeg-privacy-shot") {
                try? FileManager.default.removeItem(atPath: "/tmp/" + name)
            }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-t", "png", prefix + ".png"]
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()

        var visible = 0, hidden = 0, found = false
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
            for name in names where name.hasPrefix("clothespeg-privacy-shot") && name.hasSuffix(".png") {
                let url = URL(fileURLWithPath: "/tmp/" + name)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let count = PrivacyPixels.tally(image)
                visible += count.visible
                hidden += count.hidden
                found = true
                try? FileManager.default.removeItem(at: url)
            }
        }
        return found ? (visible, hidden) : nil
    }

    static func run() -> String {
        var lines: [String] = []
        lines.append("privacy default: sharingType raw \(WindowPrivacy.normal.rawValue)")
        lines.append("privacy permission: \(ScreenGrab.hasAccess ? "granted" : "NOT GRANTED")")
        guard let screen = NSScreen.main else {
            lines.append("privacy probe: NO SCREEN")
            return lines.joined(separator: "\n")
        }

        let box = screen.visibleFrame
        let side: CGFloat = 150
        let ordinary = make(green, at: NSRect(x: box.midX - side - 40, y: box.midY - side / 2,
                                              width: side, height: side))
        let marked = make(magenta, at: NSRect(x: box.midX + 40, y: box.midY - side / 2,
                                              width: side, height: side))
        // `CLOTHESPEG_PRIVACY_NOFLAG=1` takes the fix away: a check that
        // cannot fail is not a check. With no flag both colours must appear.
        let flag = ProcessInfo.processInfo.environment["CLOTHESPEG_PRIVACY_NOFLAG"] == nil
        if flag { marked.sharingType = .none }
        lines.append("privacy flag: \(flag ? ".none" : "left at default")")
        ordinary.orderFrontRegardless()
        marked.orderFrontRegardless()
        // The window server needs a turn before a frame contains either.
        spin(0.6)

        // 1. ScreenCaptureKit — what this app's own capture and modern
        //    recorders use. Asynchronous, so it is given its own task.
        var kit: (visible: Int, hidden: Int)?
        if ScreenGrab.hasAccess {
            let holder = Box()
            let group = DispatchGroup()
            group.enter()
            Task.detached {
                do {
                    let image = try await ScreenGrab.screenImage(of: screen)
                    holder.kit = PrivacyPixels.tally(image)
                } catch {
                    holder.kitError = error.localizedDescription
                }
                group.leave()
            }
            _ = group.wait(timeout: .now() + 20)
            kit = holder.kit
            if !holder.kitError.isEmpty {
                lines.append("privacy kit: FAILED \(holder.kitError)")
            }
        }
        lines.append("privacy kit: \(PrivacyPixels.verdict(kit))"
                     + (kit.map { ", green \($0.visible) px, magenta \($0.hidden) px" } ?? ""))

        // 2. The older window-server call, still used by some capture tools.
        let legacy = CGWindowListCreateImage(.infinite, [.optionOnScreenOnly],
                                             kCGNullWindowID, [.nominalResolution])
            .map(PrivacyPixels.tally)
        lines.append("privacy cgwindow: \(PrivacyPixels.verdict(legacy))"
                     + (legacy.map { ", green \($0.visible) px, magenta \($0.hidden) px" } ?? ""))

        // 3. The system's own screenshot command.
        let shot = systemShot()
        lines.append("privacy screencapture: \(PrivacyPixels.verdict(shot))"
                     + (shot.map { ", green \($0.visible) px, magenta \($0.hidden) px" } ?? ""))

        ordinary.orderOut(nil)
        marked.orderOut(nil)

        // The switch's wiring, not just the flag: a window built while the
        // answer is on has to pick it up at birth, and go back when it is off.
        // The saved answer is put back exactly as it was, including absent —
        // "never chosen" is not the same as "chosen off".
        let key = WindowPrivacy.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        let born = LinePanel(content: NSView())
        let atBirth = born.sharingType
        // The tip gate is part of the answer. With no code redeemed, a shared
        // window at birth is correct — judging against ".none" unconditionally
        // made this probe fail on a perfectly working locked machine.
        let shouldHide = WindowPrivacy.isHidden
        UserDefaults.standard.set(false, forKey: key)
        // The path a settings toggle actually takes: the window was made
        // earlier, so it can only be reached by walking the app's windows.
        WindowPrivacy.applyToAll()
        let afterOff = born.sharingType
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        let expectedAtBirth: NSWindow.SharingType = shouldHide ? .none : WindowPrivacy.normal
        let wired = atBirth == expectedAtBirth && afterOff == WindowPrivacy.normal
        let birthLabel = atBirth == expectedAtBirth
            ? (shouldHide ? "hidden at birth" : "shared at birth, gate off")
            : "WRONG AT BIRTH"
        lines.append("privacy window: \(birthLabel), "
                     + "\(afterOff == WindowPrivacy.normal ? "restored" : "NOT RESTORED")")

        let verdicts = [kit, legacy, shot].map { PrivacyPixels.verdict($0) }
        let passed = wired && verdicts.allSatisfy { $0 == "hidden" }
        lines.append("privacy probe: \(passed ? "PASS" : "FAIL")"
                     + " — a real screen recording (Cmd-Shift-5) still wants a look on this machine")
        return lines.joined(separator: "\n")
    }
}
