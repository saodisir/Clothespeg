import AppKit

/// A window the pointer can be over, as the capture needs it: an id to take a
/// picture of, a frame to draw a highlight around, and a name to say where the
/// picture came from.
///
/// Deliberately not `SCWindow`: this list is read from `CGWindowListCopyWindowInfo`,
/// which answers the moment it is asked and needs no permission. `SCShareableContent`
/// is the other half — it is what actually captures — and it is asked later, once,
/// for the one window that was picked. Reading both up front would make entering
/// the capture wait for an enumeration nobody has looked at yet.
struct PickableWindow: Equatable {
    let id: CGWindowID
    /// In AppKit's screen coordinates: origin bottom left, y running up.
    let frame: CGRect
    /// The app's display name, e.g. "Excel". Empty when macOS will not say.
    let owner: String
    /// Whether the window is this app's. Its picture comes from the frozen
    /// backdrop rather than from a window render — see `CaptureController`.
    var isOwn: Bool = false
}

/// Which window is under the pointer.
enum WindowPick {
    /// CG's window list is measured from the top left of the main display with
    /// y running down. Every other coordinate in this feature is AppKit's, so
    /// the flip happens once, here, and nothing downstream has to know.
    ///
    /// The main display is the anchor rather than the pointer's screen: CG's
    /// origin is the top left of the main display, whatever else is arranged
    /// around it, so this is a constant of the machine rather than a property
    /// of the capture.
    private static var mainDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    static func appKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX,
               y: mainDisplayHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// The windows on screen the pointer may land on, front to back.
    ///
    /// Front to back is the list's own order, which is why the first window
    /// containing the pointer is the right answer: it is the one a click would
    /// have reached.
    ///
    /// **This app is in the list.** A capture that cannot photograph its own
    /// panel argues with the one macOS ships: ⌘⇧4 takes whatever is on the
    /// screen, and a line of clipboard cards sitting there is on the screen.
    /// The old exclusion meant a picture of the desktop with a hole where the
    /// strip was, which is not a picture of the desktop.
    ///
    /// The two are held to different rules about layers, because the layer
    /// number means different things for each. For anyone else an ordinary
    /// window is layer 0, and everything else on a layer is a menu, a banner or
    /// the dock — none of them something a person points at and means. Ours sit
    /// above 0 *on purpose*: the line at `.floating`, a note or the search at
    /// `.statusBar`, a pinned picture at `.popUpMenu`. So "layer 0" is asked of
    /// other apps, and "nothing above our own overlay" of us.
    static func windows() -> [PickableWindow] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var found: [PickableWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int else { continue }
            let isOwn = pid_t(ownerPID) == myPID
            guard admits(layer: layer, isOwn: isOwn, alpha: alpha) else { continue }
            guard let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
            // Anything smaller than this is a tooltip, a badge, or a window
            // being animated on its way in — none of them something a person
            // points at and means.
            guard cgFrame.width >= 40, cgFrame.height >= 40 else { continue }
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            found.append(PickableWindow(id: CGWindowID(number),
                                        frame: appKit(cgFrame),
                                        owner: owner,
                                        isOwn: isOwn))
        }
        return found
    }

    /// The layer our capture overlay lives on, and the highest one a window of
    /// ours may occupy and still be something to point at.
    ///
    /// The overlay is one above this, on purpose — see `CaptureOverlayWindow`.
    static let ceiling = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Whether a window on this layer is one the pointer may land on.
    ///
    /// Arithmetic rather than a walk over the window list, so the self-test can
    /// state the rule without opening a window: the failure worth guarding is
    /// somebody tightening "ours too" back to layer 0, which is completely
    /// silent — the line would simply stop answering hovers, and a pointer over
    /// it would light up whatever is behind.
    static func admits(layer: Int, isOwn: Bool, alpha: Double) -> Bool {
        // A fully transparent window is still in the list and would answer for
        // a click it could never have taken.
        guard alpha > 0.01 else { return false }
        // Ordinary windows only for anyone else — the dock, the menu bar and
        // notification banners live on layers of their own, and a screenshot of
        // a notification is a screenshot nobody asked for.
        return isOwn ? layer <= ceiling : layer == 0
    }

    /// The frontmost window containing a point, if any.
    static func window(at point: NSPoint, in windows: [PickableWindow]) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }
    }
}
