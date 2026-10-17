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
    /// Light is CDS surface 0, `#f5f5f3`: the warm grey that lets the
    /// grouped cards' near-white read as cards. The same reasoning the white
    /// ground answered before, warmed to match the paper the rest of the app
    /// wears. Dark is CDS surface 1, `#1c1b1a`: a warm charcoal rather than
    /// the system's neutral grey, for the same reason the paper in dark mode
    /// is a warm grey and not a black.
    static let ground = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua:
            NSColor(srgbRed: 0.110, green: 0.106, blue: 0.102, alpha: 1)   // #1c1b1a
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
