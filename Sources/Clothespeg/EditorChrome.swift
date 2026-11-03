import AppKit

/// The editor's own vocabulary of surfaces, in AppKit.
///
/// The settings window is SwiftUI and uses `CDS` directly; this window is
/// AppKit, so the same few facts are restated once, here. Clay is the same
/// `#d97757`, and it stays an emphasis colour only — the picked tool, the
/// primary button — never a ground and never a text colour.
enum EditorInk {
    static let clay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    /// The word on clay: white on light, near-black on dark, where white on
    /// clay glows more than it reads.
    static let onClay = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.102, green: 0.098, blue: 0.094, alpha: 1)
            : .white
    }

    /// The hairline the CDS pill wears. A tray of controls should not read as a
    /// tray of boxes, so it is quiet — but a ring at 8% is not quiet, it is
    /// absent, and a disabled pill then looks like a hole rather than a button.
    static let ring = NSColor.labelColor.withAlphaComponent(0.14)

    /// The tray a group of controls sits on, a hair off the window ground.
    static func tray(_ appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.labelColor.withAlphaComponent(dark ? 0.07 : 0.045)
    }

    /// The surface a bar wears when it floats over the picture instead of
    /// sitting on the window's own ground.
    ///
    /// Almost opaque, and not nearly-clear: a wash of ink over a screenshot is
    /// a wash of whatever the screenshot happens to contain, and a toolbar
    /// whose contrast depends on the photograph behind it is a toolbar that is
    /// unreadable exactly when the picture is busy. The shadow does the work of
    /// saying "this is above the picture"; the surface only has to be a
    /// surface.
    static func float(_ appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: dark ? 0.14 : 0.99, alpha: 0.97)
    }

    /// The text tool's mark: two letters, drawn here.
    ///
    /// Every symbol in the character family — `textformat`, `character`,
    /// `character.cursor.ibeam` — has a localised variant, and a bundle that
    /// ships zh-Hans gets it: the first draws 格式, the others 字. In a row of
    /// icons that is a word where a shape belongs. A drawn "Aa" is the same mark
    /// in every language, and it is what the reference apps use.
    static func textGlyph(pointSize: CGFloat = 12) -> NSImage {
        let size = NSSize(width: pointSize * 2, height: pointSize * 1.5)
        let image = NSImage(size: size, flipped: false) { rect in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            NSAttributedString(string: "Aa", attributes: [
                .font: NSFont.systemFont(ofSize: pointSize, weight: .medium),
                // Black in a template image; the tint colour decides the rest.
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]).draw(in: rect)
            return true
        }
        // Template, so the button's tint (grey, clay when picked) applies.
        image.isTemplate = true
        return image
    }
}

/// Whether the toolbar says which key each tool answers to.
///
/// The letters are the one part of this window that cannot be guessed from the
/// picture: a rectangle looks like a rectangle, but "R" is a fact about this app
/// that a person either remembers or does not. A letter in the corner is
/// cheaper than a manual.
///
/// A switch rather than a fixed decision, because a hint that cannot be turned
/// off is a permanent tax on a toolbar whose whole job is to stay out of the
/// picture's way. On by default: the letters are otherwise written down nowhere
/// inside the app at all, and a feature nobody can find is a feature nobody
/// turns on.
enum ShortcutHints {
    static let defaultsKey = "editorShortcutHints"

    /// Posted when the switch moves. The windows are already open by then, and
    /// a preference that only reaches the next window is a preference that looks
    /// broken for as long as this one is open.
    static let didChange = Notification.Name("editorShortcutHintsDidChange")

    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? true }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// A rounded tray that makes a handful of controls read as one thing.
///
/// Ten bordered buttons in a row read as ten separate decisions. A screenshot
/// editor's toolbar is one decision — what am I holding — and a tray is how the
/// reference apps say so: one inset surface per idea, the tools in one, the
/// destructive action away from the reversible ones.
final class EditorGroup: NSView {
    /// Whether this tray is a surface the window is made of, or a bar floating
    /// above the picture.
    ///
    /// Two kinds because they answer to different backgrounds. A tray on the
    /// window's ground can be a 5% wash of the label colour and disappear into
    /// it, which is what makes the rows read as part of the window. The same
    /// wash floating over a photograph is a smear of the photograph.
    enum Surface {
        case tray
        case floating
    }

    private let surface: Surface
    private let inner: NSStackView

    init(_ views: [NSView], spacing: CGFloat = 4, surface: Surface = .tray) {
        self.surface = surface
        inner = NSStackView(views: views)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = surface == .floating ? 12 : 10
        layer?.cornerCurve = .continuous

        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = spacing
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        // A floating bar holds still while the picture moves under it, so its
        // edges are the only thing telling the two apart — a shadow, set once,
        // is cheaper than an `NSVisualEffectView` that re-blurs the canvas on
        // every frame of a drag.
        if surface == .floating {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 12
            layer?.shadowOffset = CGSize(width: 0, height: -3)
        }
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            // Twelve at each end, and the controls themselves left exactly where
            // they were. The buttons are spaced for the hand, and widening them
            // to make room for a corner letter moved every icon away from the
            // pointer's muscle memory — the crowding was never between the
            // buttons, it was between the last letter and the bar's own edge.
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Shows or removes one of the controls the tray was built with, in place.
    ///
    /// Not `isHidden`: a stack view whose `detachesHiddenViews` is off keeps a
    /// hidden arranged subview in the layout, so it goes on holding its width
    /// and the visible neighbour starts where it always did — an empty hole
    /// instead of a shorter tray. A visibility priority is the same hiding with
    /// the space given back, and the position is kept when it returns.
    func show(_ view: NSView, _ visible: Bool) {
        inner.setVisibilityPriority(visible ? .mustHold : .notVisible, for: view)
    }

    // Layer colours are CGColors: they are baked when they are set, so they
    // cannot follow the appearance on their own. `updateLayer` is the one place
    // AppKit asks again, and the appearance change is where it is worth asking.
    override var wantsUpdateLayer: Bool { true }

    /// A bar floating over the picture is not the picture.
    ///
    /// The canvas underneath claims a crosshair over every point it covers, and
    /// a bar being "in front" of it only decides the cursor if the bar claims
    /// one of its own. Without this, a hand reaching for 撤销 is told it is
    /// aiming at the photograph — the cursor is the only thing saying which of
    /// the two is about to receive the click.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateLayer() {
        layer?.backgroundColor = (surface == .floating
            ? EditorInk.float(effectiveAppearance)
            : EditorInk.tray(effectiveAppearance)).cgColor
        // A floating bar needs an edge of its own: over a white screenshot a
        // near-white surface has no boundary at all until something draws one.
        layer?.borderWidth = surface == .floating ? 1 : 0
        layer?.borderColor = EditorInk.ring.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A hairline between two ideas inside one tray.
///
/// The row is one surface now, so the seams have to be drawn: a tray of
/// fourteen icons with nothing between them is a tray you read one icon at a
/// time. Three seams — undo, the frame, the marks, and then the handing over.
final class EditorSeparator: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A tool: an icon sitting on a tray, filling a rounded square while it is the
/// one in hand.
///
/// `pushOnPushOff` rather than a radio group: AppKit's radio buttons want to own
/// their superview and their exclusivity, and this row is one group. Exclusivity
/// is settled in `select(_:)` — one place, one answer.
final class ToolChip: NSButton {
    /// Whether this is the tool in hand. Not the same as `state`: a fill toggle
    /// uses `state` for its own on/off, and its light comes from here too.
    var isPicked = false {
        didSet { refreshInk() }
    }

    /// The key this button answers to, drawn small in its corner.
    ///
    /// `nil` means two different things and both of them look the same — this
    /// button has no key of its own, or the hints are switched off. Keeping the
    /// switch out of the drawing is deliberate: the window decides once, when
    /// the preference moves, instead of every chip asking a `UserDefaults`
    /// question on every redraw.
    var hint: String? {
        didSet { if hint != oldValue { needsDisplay = true } }
    }

    init(image: NSImage?, tip: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.image = image ?? NSImage()
        imageScaling = .scaleProportionallyDown
        isBordered = false
        setButtonType(.pushOnPushOff)
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        refreshInk()
    }

    /// Convenience for the icons that are safe to look up — anything whose
    /// glyph is not spelled out in a language.
    convenience init(symbol: String, tip: String, target: AnyObject?, action: Selector?) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip),
                  tip: tip, target: target, action: action)
    }

    required init?(coder: NSCoder) { nil }

    /// A borderless chip has no bezel, so its alignment rect is its bounds.
    ///
    /// `NSButton` reports alignment insets describing where its bezel *would*
    /// be if it had one, and they depend on the glyph inside — four points above
    /// a hand, three below a pencil, none at all around the drawn "Aa". A stack
    /// view lays arranged views out by alignment rect, so the frame grew past the
    /// constrained 30 × 26 by an amount that differed per chip: 33 points tall
    /// here, 26 there.
    ///
    /// Everything that draws from `bounds` then disagreed with its neighbours,
    /// which is why the text tool's corner letter sat four points above the
    /// other ten. Zeroing the insets is not cosmetic — it is the statement that
    /// this button is a square of ink and nothing else, and it makes the
    /// bounds every chip draws from the same bounds.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    /// A toggle whose icon is the same picture on and off says nothing about
    /// which it is — the fill switch has to change shape, not just colour.
    func symbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)
    }

    override var isEnabled: Bool {
        didSet { refreshInk() }
    }

    private func refreshInk() {
        // `.tertiaryLabelColor` on a tray is the system's idea of "unavailable",
        // and on a 17-point glyph it is closer to "not there": a greyed 覆盖
        // that nobody can see is a button the user has to remember. Three
        // tenths of the label colour still reads as an icon that is off.
        contentTintColor = isPicked ? EditorInk.clay
            : (isEnabled ? .labelColor : NSColor.labelColor.withAlphaComponent(0.32))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let square = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        if isPicked {
            EditorInk.clay.withAlphaComponent(0.15).setFill()
            square.fill()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            square.fill()
        }
        // The icon on top: this is a borderless button, so the cell draws the
        // image and nothing else.
        super.draw(dirtyRect)
        if let hint { drawHint(hint) }
    }

    /// The key, at the size of a footnote to a footnote.
    ///
    /// Six and a half points because that is the largest size that still reads
    /// as a remark rather than as a second label, and the corner because the
    /// middle belongs to the icon. The ink is the label colour at half — the
    /// faintest that still holds up at this size, measured by looking at it
    /// rather than guessed — and never clay: clay is the word for "this one is
    /// in your hand", and a corner that borrowed it would answer that question
    /// wrongly on every unpicked button.
    ///
    /// Drawn last, over the icon: on a glyph that fills its square the letter
    /// sits on the shape rather than beside it, and at this size that is the
    /// difference between a hint and a smudge. Six and a half points of
    /// semibold is what survives being drawn over a 17-point symbol.
    ///
    /// Placed from `bounds`, which is the same 30 × 26 on every chip because
    /// `alignmentRectInsets` is zero — that is what makes eleven corners one
    /// line instead of eleven corners at eleven heights.
    private func drawHint(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(isPicked ? 0.62 : 0.5),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let origin = NSPoint(x: bounds.maxX - size.width - 2.5,
                             y: isFlipped ? bounds.maxY - size.height - 1.5 : bounds.minY + 1.5)
        string.draw(at: origin)
    }

    /// The line the corner letter's ink starts on, in the window's coordinates.
    ///
    /// The same arithmetic as `drawHint`, in the one place a check can ask for
    /// it: a screenshot shows a row of tiny letters and cannot say whether they
    /// are twelve pixels apart or twelve and a half, and the failure this exists
    /// to catch — a chip whose box is a different height from its neighbours —
    /// is invisible in prose and obvious in the numbers.
    var hintBaseline: CGFloat? {
        guard hint != nil, let root = window?.contentView else { return nil }
        let y = isFlipped ? bounds.maxY - 1.5 : bounds.minY + 1.5
        return convert(NSPoint(x: 0, y: y), to: root).y
    }
}

/// One colour, as a dot you press.
///
/// The window used to carry an `NSColorWell`, which is the whole colour
/// machinery — sliders, eyedropper, colour spaces — for the common case of
/// wanting the red one. Annotations are coloured in under a second, so the
/// seven colours a screenshot actually needs are laid out to be hit directly,
/// and the well is kept behind an eighth dot for the times it is needed.
///
/// The eighth dot is also where a colour from the well reappears: once the well
/// gives a colour that is not on the shelf, that dot wears it and takes the
/// ring, so the strip always shows what the next mark will be drawn with.
final class ColourDot: NSButton {
    /// Only the presets have one; the eighth dot borrows whatever the well
    /// last returned.
    let colour: NSColor
    private let isCustom: Bool

    var isPicked = false { didSet { needsDisplay = true } }

    /// The colour the eighth dot is currently showing, when it is not a preset.
    var borrowed: NSColor? { didSet { needsDisplay = true } }

    init(colour: NSColor = .clear, custom: Bool = false, tip: String,
         target: AnyObject?, action: Selector?) {
        self.colour = colour
        self.isCustom = custom
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Whether two colours are the same one. `NSColor` equality is by identity
    /// of the catalog entry, and a colour that has been through the panel is a
    /// different object even when it is the same value.
    ///
    /// Compared in both appearances, not in "the" one. The shelf holds system
    /// colours, which have a different value in each appearance; a style that
    /// has been saved and reloaded holds a fixed sRGB value, resolved in
    /// whichever appearance it was saved in. Compared as they are, the two
    /// disagree half the time — the picked dot then vanishes from the shelf and
    /// the eighth dot offers the ink you are already using.
    static func matches(_ a: NSColor, _ b: NSColor) -> Bool {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let x = resolve(a, name), let y = resolve(b, name) else { continue }
            if abs(x.redComponent - y.redComponent) < 0.004
                && abs(x.greenComponent - y.greenComponent) < 0.004
                && abs(x.blueComponent - y.blueComponent) < 0.004 { return true }
        }
        return a == b
    }

    private static func resolve(_ colour: NSColor, _ name: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = colour.usingColorSpace(.sRGB)
        }
        return resolved ?? colour.usingColorSpace(.sRGB)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A 12-point dot inside an 18-point cell: the cell is the target, the
        // dot is the answer. The ring then has room to sit outside it without
        // touching the neighbours.
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        if let fill = borrowed ?? (isCustom ? nil : colour) {
            fill.setFill()
            dot.fill()
            // A pale dot on a pale tray has no edge until something draws one.
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            dot.fill()
        }
        // The plus belongs to the eighth dot whatever is underneath it: it is
        // the one that opens the well, in both of its states.
        if isCustom { plus(in: dot.bounds) }
        if isPicked {
            EditorInk.clay.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        // No `super.draw`: this button has no image and no title to draw.
    }

    /// The plus that says "there are more colours than this shelf".
    private func plus(in box: NSRect) {
        let centre = NSPoint(x: box.midX, y: box.midY)
        let arm: CGFloat = 3
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre.x - arm, y: centre.y))
        path.line(to: NSPoint(x: centre.x + arm, y: centre.y))
        path.move(to: NSPoint(x: centre.x, y: centre.y - arm))
        path.line(to: NSPoint(x: centre.x, y: centre.y + arm))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        // On a borrowed colour the plus has to survive whatever that colour is.
        let ink = borrowed.map { contrastInk(for: $0) } ?? .secondaryLabelColor
        ink.setStroke()
        path.stroke()
    }
}

/// A slider that says when the hand has let go of it.
///
/// `isContinuous` is what makes the number beside the slider follow the knob
/// instead of appearing when the mouse comes up. The same switch would also
/// write the chosen style to disk on every pixel of travel, so the window keeps
/// the two apart: the style changes while the knob moves, and the file is
/// written once, here, when the drag ends.
///
/// The tracking loop runs *inside* `super.mouseDown` — NSSlider keeps the mouse
/// until the button comes up — so the line after it is the only honest place to
/// say "the drag is over". A click that does not move the knob goes through the
/// same path and commits the value it already had, which costs nothing.
final class ValueSlider: NSSlider {
    /// Whether the knob is in someone's hand right now.
    ///
    /// Named this way rather than `isTracking` because `NSCell` already means
    /// something else by that, and a slider and its cell disagreeing about a
    /// word is how a bug gets written.
    private(set) var isBeingDragged = false

    /// Called once, after the mouse comes up.
    var onCommit: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isBeingDragged = true
        super.mouseDown(with: event)
        isBeingDragged = false
        onCommit?()
    }

    /// Harness: the two halves of a drag, without a mouse.
    ///
    /// A drill cannot perform the real gesture — the tracking loop would take
    /// the run loop and never give it back — so it asks for the same state
    /// changes the gesture makes and then looks at what the caption says between
    /// them.
    func previewDrag(_ dragging: Bool) {
        isBeingDragged = dragging
        if dragging == false { onCommit?() }
    }
}
