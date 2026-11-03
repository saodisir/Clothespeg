import AppKit
import ScreenCaptureKit

/// Why a grab did not happen. Every case is worth saying out loud: a capture
/// that silently does nothing is indistinguishable from a shortcut that is not
/// registered, and the two want opposite fixes.
enum ScreenGrabError: LocalizedError {
    /// macOS has not been told this app may look at the screen.
    case noPermission
    /// The screen asked for is not one ScreenCaptureKit will admit to having.
    /// Rare, and almost always a display that was unplugged mid-gesture.
    case noDisplay
    /// The window was gone by the time it was asked for — closed, or minimised
    /// between the click and the shutter.
    case noWindow
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return L("Clothespeg may not look at your screen yet. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then open Clothespeg again.")
        case .noDisplay:
            return L("That screen could not be captured.")
        case .noWindow:
            return L("That window had closed before the picture was taken.")
        case .failed(let why):
            return why
        }
    }
}

/// Taking the picture.
///
/// ScreenCaptureKit rather than `screencapture(1)` or `CGWindowListCreateImage`.
/// The command-line tool would run as a child process and ask for its own
/// permission; `CGWindowListCreateImage` is deprecated and cannot isolate a
/// window from what is in front of it. `SCScreenshotManager` is the API Apple
/// points at from macOS 14, which is this app's floor, and it can photograph a
/// window on its own — which is the whole reason a covered window still comes
/// out whole.
///
/// Everything here is `async` and none of it touches the main actor: the wait
/// is the window server's, and a capture that blocked the main thread would
/// freeze the line under it.
enum ScreenGrab {
    /// Whether permission is already in place.
    ///
    /// Read rather than requested, so this can be asked as often as wanted —
    /// at launch, from a menu, from a self-test — without a prompt.
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Makes sure a capture may go ahead, asking once if it may not.
    ///
    /// The false-but-granted case is macOS's own trap: the consent is recorded,
    /// the running process is not restarted, and the window server keeps
    /// answering "no" until it is. So a grant that does not take is reported as
    /// "allow it and open Clothespeg again" rather than as a refusal — the two
    /// look identical from here and only one of them is the user's next step.
    static func ensureAccess() -> Bool {
        if hasAccess { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// The whole of one screen, at its own resolution.
    static func screenImage(of screen: NSScreen) async throws -> CGImage {
        try await areaImage(in: screen.frame, on: screen)
    }

    /// A rectangle of one screen, in AppKit's screen coordinates.
    ///
    /// The rectangle is clipped to the screen first. ScreenCaptureKit answers
    /// a source rect that runs past the display with black bands rather than an
    /// error, and a picture with a black band down one side is a picture that
    /// looks like a bug in the app rather than a click that ran off the edge.
    ///
    /// `excludingThisApp` is for the one caller that asks with the capture's own
    /// overlay already on the screen. A long capture takes a frame every third
    /// of a second while the dimmed window is up, and a dim is a picture of the
    /// tool rather than of the page; there is no other way to leave one window
    /// out, since a display filter can exclude applications and not windows.
    /// Every other road here asks *before* the overlay exists, which is why
    /// nothing of this app's needs leaving out of them.
    static func areaImage(in rect: CGRect, on screen: NSScreen,
                          excludingThisApp: Bool = false) async throws -> CGImage {
        let clipped = rect.intersection(screen.frame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw ScreenGrabError.noDisplay
        }
        let content = try await shareableContent()
        guard let display = display(for: screen, in: content) else {
            throw ScreenGrabError.noDisplay
        }
        // Nothing is excluded, and the app itself least of all. This used to
        // leave the whole of Clothespeg out, so that the capture's own dimmed
        // window could not be photographed as part of the backdrop it draws —
        // but there is no such window at the moment this runs: the overlay is
        // built *from* the picture this returns. What the exclusion actually
        // removed was the clipboard line, the editor and a pinned picture,
        // which are on the screen and belong in a picture of the screen.
        let excluded = excludingThisApp ? ownApplication(in: content).map { [$0] } ?? [] : []
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excluded,
                                     exceptingWindows: [])
        // The display's own space is measured from its top left corner with y
        // running down, which is neither of the two coordinate systems the
        // rest of this file speaks. This is the one place it is used.
        let local = CGRect(x: clipped.minX - screen.frame.minX,
                           y: screen.frame.maxY - clipped.maxY,
                           width: clipped.width,
                           height: clipped.height)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int((local.width * scale).rounded()))
        config.height = max(1, Int((local.height * scale).rounded()))
        // The pointer is the thing doing the pointing; a picture of it is never
        // what anyone wanted, and it would sit in the middle of every grab.
        config.showsCursor = false
        config.captureResolution = .best
        return try await shoot(filter, config)
    }

    /// One window, on its own.
    ///
    /// `desktopIndependentWindow` is what makes this worth doing separately
    /// from cropping the screen: it renders the window from its own surface, so
    /// a window half covered by another comes out whole, and one half off the
    /// edge of the display comes out whole too. Cropping the screen would give
    /// a picture of whatever happened to be in front.
    ///
    /// The size is the window's own, at the scale of the display it is on. A
    /// window smaller than its frame is not possible, and a window still
    /// animating is answered with whatever it is at that moment.
    static func windowImage(id: CGWindowID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw ScreenGrabError.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        return try await shoot(filter, config)
    }

    // MARK: The one shutter

    private static func shoot(_ filter: SCContentFilter,
                              _ config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        } catch {
            // Only the framework's own "not allowed" is translated. Everything
            // else — a window that vanished, a display that was unplugged — is
            // passed through with its own words, because those are the ones
            // that say what to do next.
            if (error as NSError).code == SCStreamError.Code.userDeclined.rawValue {
                throw ScreenGrabError.noPermission
            }
            throw ScreenGrabError.failed(error.localizedDescription)
        }
    }

    /// The list of displays and windows. Asked fresh each time: the list is a
    /// snapshot of a moment, and a window that opened while the overlay was
    /// being drawn is a window that is not in an older copy.
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false,
                                                                        onScreenWindowsOnly: true)
        } catch {
            if (error as NSError).code == SCStreamError.Code.userDeclined.rawValue {
                throw ScreenGrabError.noPermission
            }
            throw ScreenGrabError.failed(error.localizedDescription)
        }
    }

    /// This app, for the one grab that is taken with its own overlay on screen.
    ///
    /// A long capture samples the screen while the dimmed window is up, so the
    /// whole app goes rather than the one window: a display filter can leave out
    /// applications, not windows. The cost is that a surface of our own cannot
    /// appear in a scrolling capture — and a frame with a dim drawn over the
    /// page in it would be a worse bug than that.
    private static func ownApplication(in content: SCShareableContent) -> SCRunningApplication? {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.applications.first { $0.processID == pid }
    }

    /// The display behind an `NSScreen`, matched by display id rather than by
    /// geometry.
    ///
    /// Two displays that overlap in screen coordinates — mirrored, or arranged
    /// one behind another — would answer a geometric test with each other's
    /// pictures. The id is what the window server itself uses.
    private static func display(for screen: NSScreen,
                                in content: SCShareableContent) -> SCDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let wanted = CGDirectDisplayID(number.uint32Value)
        return content.displays.first { $0.displayID == wanted }
    }
}
