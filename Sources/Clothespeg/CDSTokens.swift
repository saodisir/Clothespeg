import SwiftUI

/// Design tokens taken from the Claude design system (CDS), as documented by
/// the open-claude-ui project (MIT, github.com/Caho1/open-claude-ui).
///
/// What is taken here is the *facts* — colour values, corner radii, motion
/// durations — not that project's code, which is React and of no use to this
/// app. The fit is no accident: the app's paper (`PayloadCard.paper`) and
/// Claude's warm surface ladder are already the same taste, so this is not a
/// change of style but the giving of a system to a warmth that had none.
///
/// P0 scope is the settings window only: the tokens live here so the line
/// can pick them up later (P1) without a second definition to drift.
enum CDS {
    // MARK: Colour

    /// The clay accent, `#d97757`. An emphasis colour only — selected states,
    /// switches, primary actions — never a text colour and never a ground:
    /// clay on paper is a shout, and a page of shouts is a page of nothing.
    ///
    /// Every "this one is on" state in the app wears this, and none of them
    /// wears the system accent any more (2026-11-02): a lock, a pin, a lit date,
    /// a chosen filter all used to light up in whatever blue macOS was set to,
    /// which is the one colour in the app that was not chosen. The user's own
    /// words for the fix were "这样我们所有的颜色都统一了".
    ///
    /// The number itself is written down once, as `clayInk`; this is its
    /// SwiftUI face. There used to be three copies — one here, one for the
    /// AppKit drawing, one in `EditorInk` — and three copies of a colour is
    /// three chances for one of them to be "slightly warmed" the next time a
    /// view needs a hand. `scripts/check-colours.swift` keeps it at one.
    static let clay = Color(nsColor: clayInk)

    /// `clay` for AppKit, where a `Color` cannot be handed to `setFill()`.
    ///
    /// **The only `#d97757` in the source.** Everything that means "clay" in
    /// this app resolves to this constant, in either framework.
    static let clayInk = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    /// The same clay, one step lighter: `#e9a88f`.
    ///
    /// For the one place the accent has to sit on top of somebody else's
    /// pixels — the capture overlay's frame and size badge. At full strength
    /// the frame reads as part of the picture it is drawing around, and the
    /// badge reads as a caption the app did not write. Same hue, so it is still
    /// the same colour family; lighter, so it stays a frame.
    static let claySoft = Color(nsColor: claySoftInk)

    /// `claySoft` for AppKit. The second and last orange.
    static let claySoftInk = NSColor(srgbRed: 0.914, green: 0.659, blue: 0.561, alpha: 1)

    /// The word on clay, at the sizes a word is read at: dark ink on a dark
    /// appearance, white on light — white on clay in the dark glows less than
    /// it reads.
    static func label(onClayIn scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: onClayDark) : .white
    }

    /// `#1a1918`, the ink clay wears in the dark, shared by both faces of the
    /// rule so the two cannot drift apart.
    static let onClayDark = NSColor(srgbRed: 0.102, green: 0.098, blue: 0.094, alpha: 1)

    /// The same rule for AppKit, which asks by appearance rather than by scheme.
    static let onClayInk = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? onClayDark : .white
    }

    /// The ink clay wears when the thing on it is small: `#1b1917`, in both
    /// appearances.
    ///
    /// There are exactly two answers to "what colour is the ink on clay", and
    /// the difference between them is size rather than appearance. White on
    /// `#d97757` measures about 3:1: legible at twelve points, a smudge at the
    /// six and a half points of a corner key. So the capture bar's filled chips
    /// — a 14-point glyph and a 6.5-point letter — take this one, and they take
    /// it in the light too, where the rest of the app is wearing white on clay.
    ///
    /// Kept here, beside the other rule, so that a third answer cannot be
    /// invented in a view that only wanted to look a little darker.
    static let onClaySmallInk = NSColor(srgbRed: 0.106, green: 0.098, blue: 0.090, alpha: 1)

    /// The ground the settings pages sit on, in both appearances.
    ///
    /// Light is the warm paper `#f5f5f3` — the same tone the cards on the
    /// rope wear, one calm step away from white so the grouped-form cards
    /// keep their edges. Dark is CDS surface 1, `#151515`.
    ///
    /// Note: macOS's grouped `Form` paints its own scroll background with a
    /// material that samples the desktop behind the window, so this colour is
    /// the *settings window's* ground (title bar and the strip above the
    /// tabs) rather than the in-form page area, which the form's material
    /// governs. The two are meant to read as one ground, which is why the
    /// window background now uses the same material as the form.
    static let ground = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua:
            NSColor(srgbRed: 0.082, green: 0.082, blue: 0.082, alpha: 1)   // #151515
        default:
            NSColor(srgbRed: 0.961, green: 0.961, blue: 0.953, alpha: 1)   // #f5f5f3
        }
    })

    // MARK: Shape

    /// Buttons and pills. The settings pages had four answers to "how big is
    /// a button" (2026-10-17, backlog #1); the CDS radius matrix is the
    /// excuse to have one.
    static let pillCorner: CGFloat = 999

    /// Cards and inset groups.
    static let cardCorner: CGFloat = 10

    // MARK: Motion

    /// Micro-feedback: a press, a tick. The CDS 70 ms haptic slot.
    static let microAnimation = Animation.easeOut(duration: 0.07)

    /// Geometric bite: a sliding selection, a pill that moves between tabs.
    /// The CDS 120 ms slot, as a spring.
    static let slideAnimation = Animation.spring(response: 0.18, dampingFraction: 0.85)

    /// A press asks the control to lean in by this much. Subtle on purpose:
    /// a button that visibly shrinks is a button performing, not answering.
    static let pressScale: CGFloat = 0.98
}

/// The one style the settings pages' action buttons wear.
///
/// A quiet pill: a hairline ring, a hover fill, and the clay ink only while
/// pressed. Every row button in the window used to draw its own — bordered
/// here, borderless there, small in one card and caption-sized in another —
/// which is how a page reads as four apps in one window.
struct CDSPillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? CDS.clay : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    configuration.isPressed
                        ? CDS.clay.opacity(0.10)
                        : (hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
                )
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? CDS.pressScale : 1)
            .animation(CDS.microAnimation, value: configuration.isPressed)
            .animation(CDS.microAnimation, value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }
}
