import SwiftUI

/// The colour a note is written on.
///
/// The sheet used to be a paper with a pattern drawn on it and a wash laid
/// over the pattern, which was three decisions where the reader needed one:
/// what it is made of, what is printed on it, and what colour it is. The
/// first two are gone — every sheet is a plain one now, and the whole of
/// what is chosen is the colour. What were once five papers and six washes
/// are one palette: the paper's own whites folded in beside the washes,
/// every one of them a full colour the card simply is.
///
/// Two kinds of colour share the palette, and they answer the appearance
/// differently. The palette's own colours are facts about the note: a peach
/// note is peach in the dark room too. Only the unpicked paper — nil, the
/// system colour — follows the appearance, because it is the one choice
/// that means "whatever the system thinks a sheet is". `ink(for:in:)` is
/// the same bargain on the other side: dark ink over a picked colour,
/// the system's own ink over the system's own paper.
enum NoteTint: String, CaseIterable, Identifiable, Codable {
    case cream, yellow, orange, red, green, blue, black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cream: L("Cream")
        case .yellow: L("Yellow")
        case .red: L("Red")
        case .green: L("Green")
        case .blue: L("Blue")
        case .orange: L("Orange")
        case .black: L("Grey")
        }
    }

    /// The sheet itself, not a wash over one: the colour the card is.
    ///
    /// Nil is the paper's own colour, carried here rather than in the enum
    /// so that a note which never picked a colour is not storing a colour
    /// that could fall out of step with the paper — see `background(for:)`.
    func background(in scheme: ColorScheme) -> Color {
        Self.background(for: self, in: scheme)
    }

    /// The colour of the sheet, for a note that picked one or did not.
    ///
    /// The one reader for both sides of a note: the editor's sheet, the
    /// card's sheet and the tick cut out of either are this colour, and
    /// there is no second place to be wrong about it.
    ///
    /// A picked colour no longer has a dark pair. It used to: every choice
    /// dimmed to near-black in the dark, and seven different choices became
    /// seven shades of the same hole. A colour the user picked is a colour
    /// they picked — it holds in both appearances, and the ink, not the
    /// paper, is what changes to keep it readable.
    static func background(for tint: NoteTint?, in scheme: ColorScheme) -> Color {
        guard let tint else { return PayloadCard.paper }
        switch tint {
        case .cream:  return rgb(0.980, 0.940, 0.840)
        case .yellow: return rgb(0.941, 0.914, 0.815)
        case .red:    return rgb(0.913, 0.816, 0.797)
        case .green:  return rgb(0.861, 0.893, 0.843)
        case .blue:   return rgb(0.829, 0.861, 0.899)
        case .orange: return rgb(0.938, 0.865, 0.794)
        case .black:  return rgb(0.773, 0.770, 0.769)
        }
    }

    /// The ink a note is read in, over the sheet `background` chose.
    ///
    /// Over the system colour it is the system's own ink, because the sheet
    /// is the system's own sheet. Over a picked colour it is always dark:
    /// the picked colour is always light now, and white ink on peach is not
    /// a dark mode, it is a note that cannot be read.
    static func ink(for tint: NoteTint?, in scheme: ColorScheme) -> Color {
        tint == nil ? Color.primary : rgb(0.16, 0.15, 0.14)
    }

    /// The AppKit half of the same ink, for the editor's text view and the
    /// layout manager that draws over it.
    static func nsInk(for tint: NoteTint?) -> NSColor {
        tint == nil ? .labelColor : NSColor(srgbRed: 0.16, green: 0.15, blue: 0.14, alpha: 1)
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - The view

/// One sheet, at whatever size it is given: the colour, and nothing else.
///
/// The pattern drawing is gone with the papers it belonged to. What is left
/// is the one thing every card had in common — a colour under the words —
/// and a rectangle is the whole of the drawing that needs.
struct PaperSheet: View {
    var tint: NoteTint? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(NoteTint.background(for: tint, in: scheme))
    }
}
