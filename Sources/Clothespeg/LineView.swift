import SwiftUI

enum Layout {
    /// How deep the strip is, which is a question about what hangs on it.
    ///
    /// The clipboard's cards are all one size, so its depth has always been a
    /// constant and stays one — two hundred and ten, exactly what it was. A
    /// note's height is a fact about its contents, so the notes are given the
    /// room to grow into, and the room has to come from the panel: a card
    /// taller than the panel is a card with its bottom cut off.
    ///
    /// Two depths rather than one, because the two decks are never on the rope
    /// together — so nothing has to be shared, and nothing about the clipboard
    /// half changes when the notes half grows.
    static let clipboardDepth: CGFloat = 210
    static let notesDepth: CGFloat = 344

    static func depth(for deck: Line.Deck) -> CGFloat {
        deck == .notes ? notesDepth : clipboardDepth
    }

    static let ropeTop: CGFloat = 10
    /// The pitch between neighbouring cards, not the gap between them: each
    /// card is given a slot of this width and sits in the middle of it.
    ///
    /// Tendedero's own spacing, kept deliberately. Spacing the real cards by
    /// their edges looks right until a narrow note sits next to a wide
    /// picture and the row goes uneven. A fixed pitch means the slots are
    /// always the same distance apart whatever is hung on them, which is what
    /// makes the line read as a row of pegs rather than a scatter of cards.
    static let spacing: CGFloat = 188
    /// The width of a slot, and the width a picture fills it with.
    static let cardWidth: CGFloat = 170
    /// The notes hang further apart, because a note is wider: on a snippet's
    /// pitch two of them would touch.
    static let notesPitch: CGFloat = 240

    static func pitch(for deck: Line.Deck) -> CGFloat {
        deck == .notes ? notesPitch : spacing
    }

    /// The width of a slot: what a card's frame is given, and what it reports
    /// back as its own rectangle. Always a little wider than the card inside
    /// it, which is the gap that keeps a run of notes reading as cards.
    static func slot(for deck: Line.Deck) -> CGFloat {
        deck == .notes ? NoteCardLayout.width + 20 : cardWidth
    }

    static let pinAbove: CGFloat = 9.5

    /// How deep the pill has to reach to clear the cards.
    ///
    /// One array only: the depths of the cards on the whole line. There is
    /// no `page` argument, and that is the point — the pill used to be
    /// measured against the cards currently on screen, so turning a page
    /// or switching a filter moved it up and down. The line itself only
    /// changes when a note is written, rewritten or taken down.
    ///
    /// A note is capped at `maxHeight` by its own layout, so the cap here
    /// is a guard that keeps the pill inside the panel even if that
    /// constant is ever raised. The clipboard's pictures keep their own
    /// proportions and are not capped.
    static func pillDepth(for deck: Line.Deck, line: [CGFloat]) -> CGFloat {
        let deepest = line.max() ?? 0
        guard deck == .notes else { return deepest }
        return min(NoteCardLayout.maxHeight + 2 * Frame.inset, deepest)
    }

    /// Where the pill goes: below the deepest card on the line.
    static func pillY(ropeY: CGFloat, depth: CGFloat) -> CGFloat {
        ropeY - pinAbove + PeggedView.cardOffsetBelowTop + depth + 35
    }

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// Where each card's centre goes. Evenly spaced slots, pulled in on a
    /// screen too narrow to hold them all.
    static func x(index: Int, count: Int, width: CGFloat, pitch: CGFloat) -> CGFloat {
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(pitch, max(0, width - 200) / gaps) : pitch
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

/// When the pill earns its place on the rope.
///
/// A pager with one page has nothing to page, and a filter with every card
/// already in view has nothing to narrow: the pill used to appear on the
/// notes rope merely because a recording existed, which put a control with
/// no question to ask under three cards. It comes out when there is a second
/// page, and stays while a filter or a search is in force, so the switch
/// that narrowed the line is never hidden by the narrowing it caused.
enum PagerVisibility {
    static func shows(shown: Int, matching: Int,
                      narrows: Bool, searching: Bool) -> Bool {
        shown < matching || narrows || searching
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    /// How many cards the screen has room for. The pitch is fixed, so this is
    /// known without measuring anything.
    private func fits(_ width: CGFloat, pitch: CGFloat) -> Int {
        max(1, Int((width - 200) / pitch) + 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // The three measurements the deck decides, read once here rather
            // than asked for again at each use: a card, the slot it sits in
            // and the pill under it all have to be answering about the same
            // deck, and half a layout read from one and half from the other is
            // a line with its pill in the wrong place.
            let depth = Layout.depth(for: line.deck)
            let pitch = Layout.pitch(for: line.deck)
            let slot = Layout.slot(for: line.deck)
            // Read once, like the three above it and for the same reason.
            // The hint's words are a fact about which rope is up, and the
            // list of cards is a fact about which rope is up; if one of them
            // is read here and the other is read again where it is used,
            // there is a frame in which the words belong to one rope and
            // the cards belong to the other, and the line says it is empty
            // while it is drawing something. Switching ropes is exactly when
            // that frame happens.
            let deck = line.deck
            let room = fits(width, pitch: pitch)
            let shown = line.visibleItems(room)
            // Whether the rope is empty, which is the only question the hint
            // was ever asking. Both decks answer it here so the two ropes
            // cannot drift apart on it.
            let empty = (deck == .clipboard ? line.items : line.notes)
                .allSatisfy { $0.falling }
            // The pill's ground is the whole line, not this page. A filter
            // or a search that matches nothing leaves `shown` empty, and a
            // pill measured against an empty page would rise to the rope;
            // the line's own cards are what the pill waits under.
            let wholeLine = line.onLine.filter { !$0.falling }
            let pillDepth = Layout.pillDepth(
                for: deck, line: wholeLine.map { PayloadCard.outerSize(of: $0).height })
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                // The empty rope's own words, and the whole of its motion.
                //
                // Mounted when the rope is empty and not otherwise, fading on
                // the way in and out. That is Tendedero's arrangement, kept as
                // it stands there rather than rebuilt: a hint that is only in
                // the tree while it is wanted cannot be seen arriving late,
                // and one whose only motion is an alpha cannot have its words
                // and its glass set out along different paths — one value is
                // changing on both at once, and there is nothing to disagree
                // about.
                //
                // Every version of this that moved the capsule instead —
                // sliding it down, parking it above the panel, sliding it
                // back, offsetting it, flattening it — was chasing that
                // agreement by hand, and lost. `regularMaterial` is an
                // `NSVisualEffectView`: an AppKit view living behind a
                // SwiftUI layer, moved by different machinery however the
                // motion is driven. Handing the whole capsule a single alpha
                // rather than a motion is what settles it.
                //
                // Kept inside the line's own stack, so it travels with the
                // reveal. That was once the reason it was pulled out — the
                // glass went down from under the menu bar while the words
                // stayed put — but that was a consequence of the words and the
                // glass being two layers with two motions. One alpha on the
                // whole capsule cannot come apart that way, and a hint that
                // slid in on its own would be a thing arriving from nowhere
                // rather than from the line it belongs to.
                if empty {
                    Hint(isNotes: deck == .notes)
                        .position(x: width / 2,
                                  y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                // The rope's own marks, in one container: the plus that writes
                // a note, and the lock that keeps the rope down. It hangs in the
                // gap the dip leaves — the one part of the panel no card can
                // reach, because every card hangs under the rope and the rope
                // only falls away from here.
                //
                // One container rather than two marks, so the rope carries a
                // single cluster instead of two things that happen to be near
                // each other. The clipboard's rope has the pin alone; the
                // notes' rope has both, because a plus is what writes a note
                // and the clipboard has nothing to write.
                //
                // Which marks are in it is the user's answer (see `RopeMark`):
                // a mark nobody asked for is not drawn, and a container with
                // nothing in it is not drawn either — so the default rope is
                // exactly the rope it always was.
                if !RopeMark.visibleMarks(for: line).isEmpty {
                    RopeMarks(line: line)
                        .position(x: width / 2,
                                  y: max(8, Layout.ropeY(x: width / 2, width: width) - 24))
                }

                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    let x = Layout.x(index: index, count: shown.count, width: width, pitch: pitch)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    // The slot is always its own width; a narrower card sits
                    // in the middle of it. Reporting the slot rather than the
                    // card keeps a card from swallowing its neighbour's clicks.
                    PeggedView(item: item, line: line)
                        .frame(width: slot, height: depth - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (depth - ropeY) / 2)
                }

                // Shown only when the line has something to page through, or a
                // filter or a search is hiding something, or the search field
                // is open — because a field with nowhere to be typed into is a
                // field that cannot be closed either: it would be open and
                // invisible at the same time.
                //
                // The rope being down is deliberately not a reason. The pill is
                // a pager and a filter, and it earns its place by saying
                // something about what the line is showing; an empty rope has
                // nothing to page and the hint above it already says so. The
                // lock toggle lives on the rope itself instead, where it
                // does not need the pill to exist to be found.
                // A note carrying a recording is deliberately not a reason
                // of its own any more. It used to keep the pill up over a
                // rope of three cards, all of them visible; a filter only
                // earns its place once there is more than one page to look
                // through, or once a filter is actually narrowing the line.
                if PagerVisibility.shows(shown: shown.count,
                                         matching: line.matching.count,
                                         narrows: line.narrows,
                                         searching: line.isSearching) {
                    Pager(line: line,
                          count: line.matching.count, shown: shown.count,
                          offset: line.panOffset,
                          filter: line.showing,
                          filterIsHiding: line.filterHidesSomething) {
                        line.pan(by: -1, fits: room)
                    } onForward: {
                        line.pan(by: 1, fits: room)
                    } onFilter: { option in
                        line.showing = option
                    }
                    // Below the deepest card on the line, whichever page
                    // happens to be showing. A pager the hand has to go
                    // looking for on every turn of the line is not a pager.
                    .position(x: width / 2,
                              y: Layout.pillY(ropeY: Layout.ropeY(x: width / 2, width: width),
                                              depth: pillDepth))
                    .zIndex(10)
                    // Above the cards in the same stack, and reported to them
                    // in the same breath. The hit test that decides whether a
                    // press reaches the pill is written outside SwiftUI and
                    // cannot ask what is on screen, so it guesses — and a
                    // guess about a pill that changes width with the filter
                    // and moved to the other end of the line is wrong often
                    // enough to be useless. The pill measures itself instead,
                    // and the guess goes away.
                    // Above the cards, not behind them: a pager you have to
                    // read through a screenshot is not a pager. The cards are
                    // 140pt deep and the panel is 210, so the strip along the
                    // bottom is the only space the line leaves.
                    .zIndex(1)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: shown.map(\.id))
            // Keyed off the rope being empty, which is what the hint's
            // `if` is keyed off too. This is the line that makes the
            // transition happen at all: without it the hint would appear
            // and disappear between frames rather than fading.
            //
            // It is asked about the rope rather than about `shown`, so a
            // filter that hides everything does not read as an empty line
            // and put up a hint about copying things. The rope is what the
            // hint is for.
            .animation(.easeInOut(duration: 0.3), value: empty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(depth + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .coordinateSpace(name: "lineSpace")
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
        // The pill's rectangle, resolved out of the anchor it publishes.
        //
        // An anchor carries nothing until something in the named space
        // resolves it, which is why this cannot be an ordinary preference
        // read: the reader has to be *in* the space it wants the answer in,
        // and the panel needs its own space rather than the line's.
        .onPreferenceChange(PagerRectKey.self) { rect in
            guard rect != .zero else { return }
            let moved = rect != line.pagerRect
            line.pagerRect = rect
            if moved {
                log.notice("""
                    Pill in panel at \(Int(rect.minX)),\(Int(rect.minY)) \
                    \(Int(rect.width))x\(Int(rect.height))
                    """)
            }
        }
        // Where the search field ended up, so the window that can take a key
        // is put exactly over it. Reported by the field itself rather than
        // worked out from the pill's width, because the pill is a different
        // width depending on what the filter is, whether its segments are open
        // and whether the search is showing — and arithmetic about that is
        // wrong often enough to put the caret beside the field.
        .onPreferenceChange(SearchRectKey.self) { rect in
            guard rect != .zero else { return }
            SearchController.shared.fieldDidMove(to: rect, panel: line.panelFrame)
        }
        // Where the plus ended up, for the same reason the pill reports its
        // own rectangle: the window decides whose click this is outside
        // SwiftUI, and a guess about a mark this small would be wrong most
        // of the time.
        .onPreferenceChange(PlusRectKey.self) { rect in
            guard rect != .zero else { return }
            line.plusRect = rect
        }
    }
}

/// Which marks the rope carries, and whether they are drawn at all.
///
/// Two answers, both the user's to make in the settings. On by default, so a
/// new user meets the rope with its marks on it and finds the features — the
/// button that writes a note, the one that keeps the rope down — before they
/// have read a word of the settings. The marks are small and sit in the dip
/// the rope already leaves, so leaving them on costs the rope nothing, and the
/// user who prefers the bare rope turns them off once they know they exist.
///
/// The shortcut behind each mark does not answer to this switch. Turning the
/// button off hides the mark, not the door — a shortcut nobody can see is
/// still a shortcut, and one that stopped working because a button was hidden
/// would be two settings for one thing. The same is true the other way: the
/// shortcut is recorded independently, and the button is the discoverable face
/// of a door the keyboard reaches without it.
enum RopeMark: String, CaseIterable {
    /// The plus that writes a note, on the notes' rope.
    case note
    /// The pin that keeps the rope down, on either rope.
    case prop

    /// Stored as an "off" flag so an unset answer is "on": the default rope is
    /// the rope with its marks, and a user who wants less reaches in and takes
    /// them off.
    var defaultsKey: String { "ropeMark.off.\(rawValue)" }

    /// Whether the user asked for this mark to be drawn. On unless turned off.
    static func isShown(_ mark: RopeMark) -> Bool {
        !UserDefaults.standard.bool(forKey: mark.defaultsKey)
    }

    static func setShown(_ mark: RopeMark, _ on: Bool) {
        UserDefaults.standard.set(!on, forKey: mark.defaultsKey)
    }

    /// Whether this mark belongs on the rope being drawn. The plus is what
    /// writes a note, so it is only ever on the notes' rope; the pin is about
    /// the rope itself and rides on both.
    func belongs(to deck: Line.Deck) -> Bool {
        switch self {
        case .note: deck == .notes
        case .prop: true
        }
    }

    /// Which marks the rope actually draws right now, given the deck and the two
/// switches. Reads the line's published mirror rather than `UserDefaults`, so
    /// a switch thrown in the settings while the rope is already down takes
    /// effect immediately instead of on the next time the line comes out.
    @MainActor
    static func visibleMarks(for line: Line) -> [RopeMark] {
        allCases.filter { mark in
            let on = switch mark {
            case .note: line.showsNoteMark
            case .prop: line.showsPropMark
            }
            return on && mark.belongs(to: line.deck)
        }
    }
}

/// The rope's marks: two small frosted discs side by side, and no container
/// of their own.
///
/// Each disc is the whole of the chrome there is — the same circle-and-glyph
/// the `+` hung alone here for years — so the pair reads as two of the family
/// of controls the rope already had rather than as a toolbar that arrived.
/// A shell around the two was tried and taken off: a capsule behind discs
/// that are themselves capsules is a frame around a frame, and it made two
/// buttons read as one wide thing. The cluster is drawn only when at least
/// one mark is on (see `RopeMark.visibleMarks`), so a rope with every mark
/// switched off carries nothing here at all.
private struct RopeMarks: View {
    @ObservedObject var line: Line

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RopeMark.visibleMarks(for: line), id: \.self) { mark in
                switch mark {
                case .note: noteMark
                case .prop: propMark
                }
            }
        }
        // One rectangle for the pair, reported under the key the pass-through
        // already reads, so a press on either disc is answered by this panel
        // instead of falling through to whatever is underneath. Two marks make
        // two exact rectangles, and a target the size of a nine-point glyph is
        // a target the hand misses.
        .background(
            GeometryReader { g in
                Color.clear.preference(key: PlusRectKey.self,
                                       value: g.frame(in: .named("lineSpace")))
            }
        )
    }

    /// The plus, at a step above the peg: near enough to read as part of the
    /// line, far enough that the peg and the mark are two things. A
    /// circle-and-plus rather than a bare plus — `plus.circle` carries a ring
    /// of its own, smaller than the disc behind it, and the sliver of glass
    /// between ring and disc read as a white edge in the light mode and
    /// vanished in the dark. The bare plus on the disc makes the disc's edge the
    /// only circle there is, and it is the same circle everywhere. The outer
    /// twenty-four points are hit area alone.
    private var noteMark: some View {
        RopeMarkButton(help: L("New note"),
                       symbol: "plus",
                       action: { NoteController.shared.beginNew() })
    }

    /// The lock, in the same disc and at the same size. Open while the rope
    /// is free to retract, shut and lit in the accent colour while it is
    /// propped — the same toggle the menu and the Esc offer, here where it is
    /// found at a glance on the rope itself. A lock rather than a pin,
    /// because the filter on the pill below already wears the pin for "show
    /// the pinned cards", and one glyph carrying two meanings would make the
    /// rope lie about one of them. The shut/open pair is the symbol's own two
    /// states, so the answer needs no invention.
    ///
    /// The accent is the app's own clay, not `Color.accentColor`: the system
    /// accent is whatever blue macOS is set to, which is the one colour here
    /// nobody chose (2026-11-02).
    private var propMark: some View {
        RopeMarkButton(help: line.propped ? L("Unlock") : L("Lock"),
                       symbol: line.propped ? "lock.fill" : "lock.open",
                       tint: line.propped ? CDS.clay : .secondary,
                       action: { line.onPropToggle?() })
    }
}

/// One mark inside the container: a small frosted disc carrying a glyph.
///
/// The two marks differ only in which glyph they draw and what they do, so
/// both of those are arguments rather than the whole label being one — which
/// keeps each mark at the call site to a single line and keeps this one
/// implementation of the disc the two of them share.
private struct RopeMarkButton: View {
    var help: String
    var symbol: String
    var tint: Color = .secondary
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            // The disc is deliberately the same sixteen points the lone "+"
            // wore before these two marks became a cluster — keeping the
            // original size so adding a second mark did not grow them.
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? tint : tint.opacity(0.85))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(Edge.gradient, lineWidth: 0.75))
                // The hand misses a sixteen-point disc, so the hit area is a
                // twenty-four-point circle around it — the same reach the mark
                // had on its own, so the cluster is not harder to hit than the
                // plus it replaces.
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Where the rope's marks ended up, measured rather than assumed.
struct PlusRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// One of the two arrows on the pill, and the one place a hold means more
/// than one press.
///
/// Written out rather than kept as a `Button` because a `Button` answers on
/// release and only once: holding one down gave exactly one page and then
/// nothing, which is the whole complaint this answers. A gesture with a zero
/// distance sees the press itself, so the first page is there under the finger
/// and the repeats are a timer the finger can end by lifting.
///
/// **The speed ramps rather than sitting at one interval.** A swipe is an
/// analogue gesture — ten points moves a little, eighty moves a lot — so a
/// single fixed rate cannot match it: too fast and every hold overshoots the
/// card being looked for, too slow and reaching the end means thirty presses.
/// Slow to start and quickening answers both, which is what Finder's arrow
/// buttons and every list scroller do.
///
/// The press-and-hold also only works because the target is bigger than the
/// glyph. At the sixteen points this was, a hand that drifted while holding
/// left the button and the repeats stopped mid-run — the acceleration would
/// have been a way to miss cards rather than to reach them. Twenty-two wide
/// and sixteen tall is still small enough to read as an arrow beside the
/// counter rather than as a target in its own right.
private struct PagerStep: View {
    enum Direction {
        case back, forward

        var symbol: String { self == .back ? "chevron.left" : "chevron.right" }
    }

    let direction: Direction
    /// How far the arrow leans while the pointer is on it, from the pill.
    let lean: CGFloat
    let action: () -> Void

    @State private var held = false
    @State private var timer: Timer?

    /// How long the first hold waits before it starts repeating.
    ///
    /// Long enough that an ordinary press — which is most of them — is one
    /// page. Short enough that a hand deliberately resting on the arrow is not
    /// left wondering whether it registered.
    private static let repeatDelay: TimeInterval = 0.35
    /// Where the repeats start, and where they are allowed to end up. The
    /// floor is what keeps a long hold from becoming a blur: at forty-five
    /// milliseconds a card is still countable.
    private static let fast: TimeInterval = 0.045
    private static let slow: TimeInterval = 0.13

    var body: some View {
        Image(systemName: direction.symbol)
            .font(.system(size: 8, weight: .bold))
            // One colour for both arrows, whatever end they sit at — and no
            // `.disabled` either, which is what made the two differ in the
            // first place: `secondary` is a semantic colour, and inside a
            // disabled button it resolves to its own dimmer variant, so the
            // arrow at the start sat a shade below the one at the end. A press
            // at either end is a no-op anyway — `pan` clamps — so the only
            // thing `.disabled` ever did here was unbalance the pill.
            .foregroundStyle(Color.secondary)
            .offset(x: lean)
            .frame(width: 22, height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !held else { return }
                        held = true
                        // Straight away, so the press is not a press that has
                        // to wait to be told it worked.
                        action()
                        timer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay,
                                                     repeats: false) { _ in
                            MainActor.assumeIsolated { ramp(from: Self.slow) }
                        }
                    }
                    .onEnded { _ in stop() }
            )
    }

    /// Keeps going, a little faster each time, until the finger lifts.
    ///
    /// One timer rescheduling itself rather than an interval that shrinks: a
    /// repeating timer cannot change its own period, and asking it to be a
    /// little quicker each time is a piece of arithmetic done here instead.
    private func ramp(from interval: TimeInterval) {
        action()
        let next = max(Self.fast, interval * 0.85)
        if next <= Self.fast {
            timer = Timer.scheduledTimer(withTimeInterval: next, repeats: true) { _ in
                MainActor.assumeIsolated { action() }
            }
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: next, repeats: false) { _ in
                MainActor.assumeIsolated { ramp(from: next) }
            }
        }
    }

    private func stop() {
        held = false
        timer?.invalidate()
        timer = nil
    }
}

/// How much is on the line and where in it you are, so a line with more on
/// it than fits says so. Without this there is no way to tell that panning
/// did anything.
///
/// The arrows step as well, for the times a trackpad is not to hand: a wheel
/// panning sideways is clumsy on a Mac and there is no keyboard focus to
/// bind, so these are the one direct way to reach a particular card.
private struct Pager: View {
    let count: Int
    let shown: Int
    let offset: Int
    let filter: Line.Filter
    /// Whether the filter lets anything through that would otherwise be
    /// hidden. When nothing is hidden the control is a page counter and the
    /// segments would have nothing to say.
    let filterIsHiding: Bool
    var onBack: () -> Void
    var onForward: () -> Void
    var onFilter: (Line.Filter) -> Void

    /// The line, for the two things this control does to it that are not "tell
    /// it which way to page": opening the search, and saying whether a search
    /// is in force.
    ///
    /// Written out rather than left to the memberwise initialiser, because
    /// that one puts every closure last and the call site would then read as
    /// a list of numbers with three actions buried at the end of it. Here the
    /// order is the order the control is laid out in.
    @ObservedObject var line: Line
    @ObservedObject private var search = SearchController.shared.model

    /// How far open the dates are: 0 is the clock alone, 1 adds the two named
    /// days, 2 adds the row of them.
    ///
    /// Folding in three steps because dates are the filter that gets used
    /// least — so the state it is shut in is the one that has to be cheap, and
    /// cheap means a single icon where the other two controls are.
    ///
    /// Closes along with the filter's segments: both are the line offering
    /// choices about what to look at, and leaving one open while closing the
    /// other leaves two answers on screen to a question that takes one.
    @State private var datesLevel = 0

    init(line: Line, count: Int, shown: Int, offset: Int,
         filter: Line.Filter, filterIsHiding: Bool,
         onBack: @escaping () -> Void,
         onForward: @escaping () -> Void,
         onFilter: @escaping (Line.Filter) -> Void) {
        self.line = line
        self.count = count
        self.shown = shown
        self.offset = offset
        self.filter = filter
        self.filterIsHiding = filterIsHiding
        self.onBack = onBack
        self.onForward = onForward
        self.onFilter = onFilter
    }

    @State private var expanded = false
    /// How far the chevron leans while pressed. Owned here so both arrows
    /// lean the same amount rather than one being nudged and one not.
    @State private var chevronOffset: CGFloat = 0

    private var atStart: Bool { offset <= 0 }
    private var atEnd: Bool { offset + shown >= count }

    @Environment(\.colorScheme) private var scheme

    /// The line between two parallel buttons. It carries five points of air on
    /// each side and nothing else — every button on the pill meets it flush,
    /// with its own four points inside — so the distance from a divider to
    /// whatever it separates is the same on the left as on the right, and the
    /// same for every pair of neighbours on the pill.
    private var pillDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 0.5, height: 11)
            .padding(.horizontal, 5)
    }

    /// One colour actually worn by a note, system colour included. The dot
    /// is the colour itself, ringed in clay while it is one of the colours
    /// being looked at — the same "lit means on" the pin and the waveform
    /// wear. Dots add up rather than replace one another; pressing a lit
    /// dot takes just that colour out of the set.
    private func tintDot(_ choice: NoteTintChoice) -> some View {
        let chosen = line.showingTints.contains(choice)
        return Button {
            var next = line.showingTints
            if chosen { next.remove(choice) } else { next.insert(choice) }
            line.showingTints = next
        } label: {
            // The system colour is the note's own paper: near white in the
            // light, near black in the dark. One circle that follows the
            // appearance, not a half-and-half one that is neither. The rim
            // is what keeps a near-white dot visible on a pale pill and a
            // near-black one visible on a dark one.
            Circle()
                .fill(choice.background(in: scheme))
            .overlay(
                Circle().strokeBorder(chosen ? CDS.clay : Color.primary.opacity(0.25),
                                      lineWidth: chosen ? 1.5 : 0.75)
            )
            .frame(width: 11, height: 11)
            // Three points of air either side and the pill's own
            // eighteen-point row: a dot is as tall as every other icon
            // button here, so the capsule does not grow a second line.
            .padding(.horizontal, 3)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chosen ? String(format: L("Stop watching %@ notes"), choice.label)
                     : String(format: L("Watch %@ notes"), choice.label))
    }

    /// Which cards are on the rope, out of how many there are: "1–4 / 4".
    ///
    /// The same shape whatever the count is. It was showing the total alone
    /// when everything fitted, which meant the form of the number changed with
    /// how many things happened to be on the line — four cards said "4" and
    /// forty said "1–9 / 40" — and a counter whose meaning depends on the
    /// number it is showing is two things to read rather than one. The range
    /// is what is on the rope, the slash is everything, and both are always
    /// there.
    ///
    /// The number after the slash is what the filter and the search between
    /// them let through, not what was copied. A count that said "of 200" while
    /// three cards are on the rope because of what was typed into the field
    /// would be describing a line the user is not looking at.
    private var countLabel: String {
        let last = min(offset + shown, count)
        guard count > 0 else { return "0" }
        return "\(offset + 1)–\(last) / \(count)"
    }



    var body: some View {
        HStack(spacing: 0) {
            // The pages first, then the count, then the filter on the right.
            // The filter began on the left, which put it beside the back
            // arrow — and the back arrow is grey on the first screen of a
            // freshly filtered line, because there is nothing before it. Two
            // dead controls at one end of a small pill, and the live one at
            // the other. On the right it sits beside the arrow that is always
            // live.
            HStack(spacing: 6) {
                PagerStep(direction: .back, lean: chevronOffset, action: onBack)
                Text(countLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                PagerStep(direction: .forward, lean: -chevronOffset, action: onForward)
            }
            .padding(.leading, 4)

            // Everything past the counter narrows the line, and a note is
            // the one thing on it that cannot be narrowed by: it was not
            // copied, so it has no kind and no app it came from, and the day
            // it was written is written on the card. So the whole right-hand
            // half belongs to the clipboard, and on the notes the pill is
            // the counter with its two arrows — which is every way there is
            // to move along a list of notes.
            if line.deck == .clipboard {
                pillDivider

                // The segments, or the one icon that opens them.
                if filterIsHiding || expanded {
                    HStack(spacing: 0) {
                        ForEach(Array(Line.Filter.allCases.enumerated()), id: \.element) { index, option in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.22))
                                    .frame(width: 0.5, height: 11)
                            }
                            Button {
                                onFilter(option)
                                // Closed in the same turn as the choice.
                                // Deferring it left the pill in two states at once
                                // for a frame, and the row redrew with one width
                                // while the press was still being delivered.
                                withAnimation(.easeOut(duration: 0.14)) { expanded = false }
                            } label: {
                                Text(option.label)
                                    // The same weight whatever is chosen: a heavier
                                    // weight is wider, and a row whose widths change
                                    // as one is chosen moves every segment after it,
                                    // so the one being chosen slides out from under
                                    // the finger.
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(filter == option ? CDS.clay : Color.secondary)
                                    // Seven between neighbours, four at the row's
                                    // two ends — the same air the icon buttons
                                    // carry, so a divider sits evenly between
                                    // whatever it separates, folded or not.
                                    .padding(.leading, index == 0 ? 4 : 7)
                                    .padding(.trailing, index == Line.Filter.allCases.count - 1 ? 4 : 7)
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .fixedSize()
                } else {
                    Button {
                        // The row of days closes with the segments opening: both
                        // are the line offering choices about what to look at, and
                        // two open at once is two answers to one question.
                        if datesLevel > 0 { withAnimation(.easeOut(duration: 0.14)) { datesLevel = 0 } }
                        withAnimation(.easeOut(duration: 0.16)) { expanded = true }
                    } label: {
                        // Icon and name. The name is only here when a filter is in
                        // force — which is the whole time it is read — and it is
                        // what turns a number into an explanation: "1–9 / 23" says
                        // how many, "文件" says why the other fourteen are not
                        // here. Without it a copy that just arrived is missing and
                        // there is nothing on screen to account for it.
                        HStack(spacing: 3) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 9, weight: .semibold))
                            // The name is only here when a filter is in force,
                            // which is the only time there is a name to read. With
                            // none set the icon is the whole of it and stays the
                            // grey it always was — an icon in the accent colour
                            // with nothing behind it says "on" when it is off.
                            if filterIsHiding {
                                Text(filter.label)
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .foregroundStyle(filterIsHiding ? CDS.clay : Color.secondary)
                        // The one shape every icon button on the pill wears:
                        // content, four points of air on each side, eighteen
                        // points tall. The divider outside carries the rest of
                        // the gap, the same five points for every neighbour, so
                        // the distance from a divider to a button reads the same
                        // whichever pair of them you look at — and the height is
                        // a number the pill's own padding knows, so the row
                        // stays as slim as it was before the pin joined it.
                        .padding(.horizontal, 4)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                pillDivider

                // The search, after the filter and not before it. The filter
                // says what kind of thing is being looked at and the search
                // says which one, so the left-to-right reading is from the
                // broader question to the narrower — and the filter's icon
                // does not move when the search opens, which is what keeps
                // the eye where it was.
                if search.isOpen {
                    // The field itself, on the line, so the window that takes
                    // the key has something to be exactly on top of. It
                    // reports its own rectangle; the window is moved to match
                    // rather than the field being told where the window is,
                    // because the field is what the user clicks.
                    //
                    // Nothing is said here about there being no matches. The
                    // count on the left already says "0", and a sentence about
                    // it would be drawn in the same place as the field — which
                    // is covered by the window that takes the caret, so the two
                    // would be read on top of each other. A count of zero is a
                    // number everyone can read; "nothing matched" is a sentence
                    // about a number, and it is not worth a collision to say.
                    SearchField(search: search)
                } else {
                    SearchButton(line: line, search: search)
                }

                pillDivider

                // The pin, after the search and before the dates, because it
                // is the one of the four used least: a switch the user threw
                // rather than a question the line answers, so it wears no
                // words and needs no unfolding — one icon, lit when the line
                // is looking at watched cards alone, unlit when it is not.
                Button {
                    line.showingPinned.toggle()
                } label: {
                    Image(systemName: line.showingPinned ? "pin.fill" : "pin")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(line.showingPinned ? CDS.clay : Color.secondary)
                        .padding(.horizontal, 4)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(line.showingPinned ? L("Watching what is pinned") : L("Watch what is pinned"))

                pillDivider

                DateButton(line: line, level: $datesLevel)
            } else {
                // Two questions a note can answer that a copy cannot: the
                // colour it wears (the system colour counts) and whether it
                // carries a voice. Each appears only when there is something
                // for it to find. Colours are drawn as dots rather than
                // folded into a menu — three colours in use are three dots,
                // and any number of them may be lit at once.
                let dots = line.pillTints
                if !dots.isEmpty {
                    pillDivider
                    HStack(spacing: 0) {
                        ForEach(dots) { choice in tintDot(choice) }
                    }
                }
                if line.hasRecordings || line.showingRecordings {
                    pillDivider
                    Button {
                        line.showingRecordings.toggle()
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(line.showingRecordings ? CDS.clay : Color.secondary)
                            .padding(.horizontal, 4)
                            .frame(height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(line.showingRecordings
                          ? L("Watching recorded notes") : L("Watch recorded notes"))
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        // Where the pill is, for the panel's hit test.
        //
        // Inside the pill, measuring the pill, and read out through the
        // line's own space. The pill is placed with `.position`, which takes
        // it out of the layout — so the reader that used to sit around it was
        // measuring what was around it, which was the panel: a rectangle the
        // width of the screen. That rectangle contained the pill often enough
        // that the controls worked until the pill grew wide enough for the
        // difference to matter, and a press that misses it goes to the app
        // underneath, which looks exactly like a button that does nothing.
        .background(
            GeometryReader { g in
                Color.clear.preference(key: PagerRectKey.self,
                                       value: g.frame(in: .named("lineSpace")))
            }
        )
        // The pill is one colour at all times: a filter is not an event that
        // the whole control changes to mark, it is a choice among six, and
        // the choice is said by the chosen word being lit. A pill that turns
        // a colour says something happened; this one says what is set.
        .background(.regularMaterial, in: Capsule())
        // Widens from the middle rather than growing to the right, so the
        // count on the left does not slide away from under the eye while the
        // field is opening. The pill is one control and it opens about its
        // centre, the way a menu opens about the button that opened it.
        .animation(.easeOut(duration: 0.16), value: search.isOpen)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { chevronOffset = inside ? -1.5 : 0 }
        }
        // Collapses when something else says so — a swipe, a new copy, the
        // line tucking away. A press inside the pill is the pill's business,
        // so choosing a filter does not close it under the finger choosing it.
        //
        // The dates close with it and for the same reasons. Both are the line
        // offering choices about what to look at, and both should be out of
        // the way once the look has moved on — a row of days still hanging
        // there after a swipe is a row that was not listening.
        .onReceive(NotificationCenter.default.publisher(for: .filterCollapsed)) { _ in
            withAnimation(.easeOut(duration: 0.14)) {
                expanded = false
                datesLevel = 0
            }
        }
    }
}

/// What an empty line says, which is a different thing to say about each of
/// the two it can be showing.
///
/// A line with no copies on it is waiting for one, and the waiting is the
/// whole of what to do. A line with no notes on it is also waiting, but for
/// something nobody is going to do by accident — so this is where the
/// shortcut goes, because the one moment it is worth reading is the moment
/// there is nothing to look at and nothing on screen to click.
private struct Hint: View {
    /// Which rope the hint hangs under, as a value rather than a reference:
    /// a Bool that changes is a change SwiftUI can see, and the words follow
    /// the deck the moment the rope does.
    let isNotes: Bool

    private var words: String {
        isNotes
            ? L("Press the + above the rope to write a note")
            : L("Copy something and it will hang here")
    }

    var body: some View {
        Text(words)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // The same frosted pill the pager wears: one material, one
            // shape, so the two capsules read as one family.
            //
            // Nothing here moves, and nothing here is given an animation of
            // its own — that is the arrangement, not an accident of it. The
            // words and the glass could not be made to travel as one, and
            // every attempt to do it by hand failed: a slide, a park, an
            // offset, a flattened bitmap. `regularMaterial` is an
            // `NSVisualEffectView` — an AppKit view living behind a SwiftUI
            // layer — and the two are moved by different machinery however
            // the motion is driven, so they part company in the middle of it
            // every time.
            //
            // What settles it is that the capsule is not moved at all. Its
            // only change is one alpha covering both of them, so there is no
            // second path to disagree about. A view that never travels
            // cannot arrive at two different times.
            //
            // So this is exactly Tendedero's hint: a text, a frosted pill,
            // and no modifiers. Anything added here has to earn its place
            // against that.
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Edge.rope, lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

/// Where the pill actually is, measured rather than assumed.
struct PagerRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension Notification.Name {
    /// The filter's segments should close — said by a swipe or a new copy, to
    /// something that cannot close itself.
    static let filterCollapsed = Notification.Name("app.clothespeg.filterCollapsed")
    /// A finished note has gone on the line, so the line wants to be down.
    ///
    /// Said by the line rather than by the window, because the window finishes
    /// a note in three ways and only one of them ends with anything hanging —
    /// and the line is the only thing that knows which one happened.
    static let noteHung = Notification.Name("app.clothespeg.noteHung")
}
