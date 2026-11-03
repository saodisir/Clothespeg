import AppKit

/// The capture bar's colours, asked of the appearance it is about to be drawn
/// in.
///
/// The bar used to be one hardcoded dark surface with white ink, which was
/// right for exactly one of the two appearances this app supports: a person
/// who had chosen Light got a warm-white settings page, a warm-white editor
/// and a black bar floating at the bottom of the screen. The user's words for
/// the fix were "暗色就是暗色，亮色就是亮色，风格统一了".
///
/// Two families of drawing, and they answer to different backgrounds:
///
/// - **The bar is chrome.** It floats above the screen it is photographing, so
///   it wears what the rest of the app wears: the editor's floating surface in
///   either appearance, and ink that is white in the dark and near-black in the
///   light. Everything else on the bar — a chip's fill, a letter, a divider —
///   is that one ink at some alpha, so there is a single thing to change.
/// - **The frame, the eight handles and the size badge are marks on somebody
///   else's pixels.** They keep the softened clay and the dark hairlines they
///   have in both appearances, because what they sit on is the picture rather
///   than the app's own ground.
///
/// Clay (`CDS.clayInk`) is an emphasis colour in both appearances and stays as
/// it is; the ink that lands on top of clay is dark in both, because white on
/// clay at 6.5 points is not faint, it is gone.
enum CaptureInk {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The surface the bar floats on.
    ///
    /// The editor's own floating surface rather than a second colour that is
    /// nearly the same: the capture bar and the editor's bar are the same object
    /// in this app's vocabulary — a row of tools above a picture — and two
    /// surfaces a few percent apart is exactly the "two apps" the design tokens
    /// exist to prevent.
    static func surface(_ appearance: NSAppearance) -> NSColor {
        EditorInk.float(appearance)
    }

    /// The ratio menu, one step off the bar so it reads as a sheet above it.
    ///
    /// Nearly opaque, unlike the bar: a menu with three percent of a photograph
    /// showing through it is a menu with a stain on it, and this is the one
    /// surface here that has small text on it.
    static func panel(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor(white: 0.135, alpha: 0.98)
                           : NSColor(white: 1.0, alpha: 0.99)
    }

    /// The bar's own ink: white in the dark, near-black in the light.
    ///
    /// Every other ink on the bar is this one at some alpha, which is what makes
    /// "does this read in both appearances" a question with one answer instead
    /// of one answer per label.
    static func ink(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor(white: 0.96, alpha: 1)
                           : NSColor(white: 0.09, alpha: 1)
    }

    /// The dark ink clay wears — the same in both appearances.
    ///
    /// Not `CDS.onClayInk`, which is white on a light appearance, because that
    /// rule was written for a button's label and this one is written for a
    /// 6.5-point letter and a 14-point glyph. A white letter on clay at that
    /// size is not a faint hint, it is an absent one. Both rules live together
    /// in `CDS` so that the difference stays a decision rather than a drift.
    static let onClay = CDS.onClaySmallInk
}
