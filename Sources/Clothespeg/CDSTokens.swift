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
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)

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

    /// The word on clay: dark ink on a dark appearance, white on light —
    /// white on clay in the dark glows less than it reads.
    static func label(onClayIn scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.102, green: 0.098, blue: 0.094) : .white
    }

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
