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
    /// `excluding` is this app's pid. Without it the strip along the top of
    /// the screen and the capture's own window are candidates, and the capture
    /// would offer to photograph itself.
    static func windows(excluding pid: pid_t) -> [PickableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var found: [PickableWindow] = []
        for info in list {
            // Ordinary windows only. Dock, the menu bar, notification banners
            // and the like live on layers of their own, and a screenshot of a
            // notification is a screenshot nobody asked for.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            // A fully transparent window is still in the list and would answer
            // for a click it could never have taken.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(ownerPID) != pid else { continue }
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
                                        owner: owner))
        }
        return found
    }

    /// The frontmost window containing a point, if any.
    static func window(at point: NSPoint, in windows: [PickableWindow]) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }
    }
}
