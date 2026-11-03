import AppKit
import UniformTypeIdentifiers

/// The picture editor, and the window it lives in.
///
/// Replaces the trip through Preview that `Markup` used to make: Preview is a
/// document window that knows nothing about this app, it edits the file behind
/// the app's back, and the card only learns about the change because a folder
/// is watched for writes. This one knows the picture is a card on a line, so
/// writing back is a write plus a redraw rather than a guess.
///
/// One editor at a time was a guess, and it was wrong.
///
/// The old comment here said two windows would mean two answers to "which card
/// does this write back to" — but a window knows its own file, so there was
/// never a second answer to give. What two windows on the same file *would*
/// mean is one overwriting what the other has not saved yet, and that is the
/// only case worth preventing: opening a picture that already has a window
/// brings that window forward instead of making a second one.
@MainActor
final class ImageEditor {
    static let shared = ImageEditor()
    private var controllers: [URL: EditorWindowController] = [:]

    /// Whether this file is one the editor can open: pictures, not PDFs. A PDF
    /// still goes to Preview, which knows what a page is.
    static func canOpen(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// How many pictures are being edited right now. For the harness, which
    /// cannot otherwise see a dictionary.
    var previewOpenCount: Int { controllers.count }

    func open(_ url: URL) {
        let key = url.standardizedFileURL
        if let open = controllers[key] {
            open.show(url: url)
            return
        }
        let controller = EditorWindowController(url: url)
        controllers[key] = controller
        controller.onClose = { [weak self] in self?.controllers.removeValue(forKey: key) }
        controller.show(url: url)
    }
}

/// The window, its floating bars, and the wiring between them.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let canvas: EditorCanvasView

    /// Three bars floating over the picture, and a drawer under the middle one.
    ///
    /// They were two rows bolted to the top of the window until this round:
    /// ninety-three points of chrome taken out of the picture's share whether
    /// or not a colour was being chosen, in a window that is rarely tall enough
    /// to begin with. A bar that floats costs the picture nothing, and the ones
    /// the reference apps use float for the same reason.
    ///
    /// Three and not one, because the three groups answer three questions that
    /// should not have to be told apart by their icons:
    ///
    /// - left, where a hand looks for history: undo and redo;
    /// - the middle, the biggest and the reason the window exists: what am I
    ///   holding;
    /// - right, as far from the tools as the window allows: how does this end,
    ///   and how big am I looking at it.
    private var leftIsland: EditorGroup!
    private var centreIsland: EditorGroup!
    private var rightIsland: EditorGroup!
    /// The numbers, the ink, and the crop frame's shape, hanging under the
    /// middle bar — the same surface, a breath below it, so the two read as one
    /// thing with a drawer rather than as two bars that happen to be near.
    private var drawer: EditorGroup!
    private var drawerSeamInk: EditorSeparator!
    private var drawerSeamFrame: EditorSeparator!
    /// A second press on the tool already in hand folds the drawer away, for a
    /// picture that needs the room more than it needs the numbers.
    private var drawerFolded = false

    private var undoButton: NSButton!
    private var redoButton: NSButton!
    /// The two ways to spend the work: take a copy of the picture, or replace
    /// the file it came from.
    ///
    /// Neither one closes the window. Closing belongs to the traffic lights —
    /// they were always there, and a 取消 button beside them was a third way to
    /// do what they already do, sitting in the row where a mis-aimed click is
    /// most expensive.
    ///
    /// They are `ToolChip`s now, not pills. A row of glyphs with two capsules
    /// at the end of it reads as two kinds of thing sharing a shelf; the two
    /// verbs are part of the same row and wear the same clothes.
    private var copyButton: ToolChip!
    private var writebackButton: ToolChip!
    /// How big the picture is being looked at: two steps and a percentage.
    ///
    /// The percentage is a button, not a label, because the numbers worth
    /// returning to (fit, 100%, 200%) are worth one press each, and a popup
    /// that only ever shows fixed items cannot also show "38%".
    private var zoomOutButton: ToolChip!
    private var zoomInButton: ToolChip!
    private var zoomLabel: NSButton!
    /// The seven colours a screenshot needs, plus the one that opens the well.
    private var presetDots: [ColourDot] = []
    private var customDot: ColourDot!
    private var primaryLabel: NSTextField!
    private var primarySlider: ValueSlider!
    private var secondaryLabel: NSTextField!
    private var secondarySlider: ValueSlider!
    /// The sentence that stands in the drawer when there are no numbers to
    /// adjust. A row of dead sliders with dashes over them does not read as
    /// "nothing applies here", it reads as broken.
    private var stripHint: NSTextField!
    private var fillToggle: ToolChip!
    private var boldButton: ToolChip!
    private var italicButton: ToolChip!
    private var aspectPopup: NSPopUpButton!
    private var toolButtons: [EditorTool: ToolChip] = [:]

    /// The observer that keeps the corners in step with the switch on the
    /// settings page. Held rather than left to the centre: a block observer is
    /// not removed by `removeObserver(self)`, so without the token a closed
    /// window would go on being told about a preference it can no longer show.
    private var hintObserver: NSObjectProtocol?

    private var currentTool: EditorTool = .select
    /// What each tool is set to, kept between tools so a highlighter is still
    /// yellow and wide when it comes back.
    private var styles: [EditorTool: ToolStyle] = [:]
    /// What the two sliders currently mean. Kept so a slider action knows which
    /// field to write without deriving it again from the tool.
    private var primaryField: StyleField = .width
    private var secondaryField: StyleField = .opacity

    private var document: EditorDocument?
    private var url: URL?
    /// Whether the picture on disk has already been copied aside this session.
    private var backedUp = false
    private var saved = true
    /// Which press each action icon is currently showing the result of. See
    /// `flash(_:_:backTo:)`.
    private var flashes: [ObjectIdentifier: Int] = [:]

    var onClose: (() -> Void)?

    /// The editor that last borrowed the shared colour panel.
    ///
    /// `NSColorPanel` hands out `setTarget`/`setAction` but will not say who the
    /// target is, and one panel serves the whole process. Someone has to
    /// remember, and it is better remembered here than guessed at close time.
    private static weak var panelOwner: EditorWindowController?

    /// The shelf of colours, in the order they are laid out.
    ///
    /// System colours rather than hex: they are already tuned for both
    /// appearances, and an annotation that has to be legible over a screenshot
    /// does not want to be the same red on a light and a dark desktop. Red
    /// first because it is what a red pen is.
    private static let presetColours: [(name: String, colour: NSColor)] = [
        ("Red", .systemRed),
        ("Orange", .systemOrange),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Cyan", .systemCyan),
        ("Blue", .systemBlue),
        ("Purple", .systemPurple),
    ]

    /// The style the two rows are currently describing: the words being typed,
    /// else the picked-up mark, else the tool in the hand.
    private var stripStyle: ToolStyle {
        canvas.editingText?.style ?? canvas.selected?.style ?? style(for: currentTool)
    }

    init(url: URL) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        canvas = EditorCanvasView(frame: .zero)
        super.init()
        // What the tools were left at last time, before the first control is
        // built: a slider that is drawn at 6 and then jumps to 12 has to be
        // told once, at the start, not corrected a frame later.
        styles = EditorStyleStore.load()
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Wide enough for three bars on one line. The middle one is centred and
        // the right one is pinned to the edge, so a narrow window slides them
        // into each other — the minimum is where they stop touching with a
        // margin left, not a number about the picture. Zoom moving into the
        // middle bar took this down to 780; the five extra points of air at each
        // end of each bar, added for the corner letters, cost a little back:
        // 780 still leaves 34.
        window.minSize = NSSize(width: 780, height: 440)
        window.titlebarAppearsTransparent = false
        buildContent()
        canvas.onZoom = { [weak self] scale in
            self?.zoomLabel.title = "\(Int((scale * 100).rounded()))%"
        }
        // The bars step out of the way of a drag: a picture drawn on towards the
        // top edge would otherwise be drawn underneath them.
        canvas.onDragActive = { [weak self] active in self?.fadeBars(active) }
        canvas.onCommand = { [weak self] command in self?.perform(command) }
        canvas.onChange = { [weak self] in self?.pictureChanged() }
        canvas.onTool = { [weak self] tool in self?.select(tool) }
        canvas.onSelect = { [weak self] mark in self?.selectionChanged(to: mark) }
        canvas.onCrop = { [weak self] rect in self?.cropChanged(rect) }
        select(.select)
        applyShortcutHints()
        hintObserver = NotificationCenter.default.addObserver(
            forName: ShortcutHints.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            // No queue: the post itself is on the main thread (a settings
            // switch, a drill), and a nil queue delivers it then and there.
            // Handing it to the main queue instead would defer it to the next
            // turn of the run loop, which turns "does the switch reach the
            // corners" into a question you have to wait a frame to answer.
            MainActor.assumeIsolated { self?.applyShortcutHints() }
        }
    }

    deinit {
        if let hintObserver { NotificationCenter.default.removeObserver(hintObserver) }
    }

    func show(url: URL) {
        load(url: url)
        NSApp.activate(ignoringOtherApps: true)
        if window.isVisible == false { placeUnderTheLine() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Puts the window under the line rather than in the middle of the screen.
    ///
    /// The line is a strip hanging from the top of the screen, and it retracts
    /// when it loses focus. A window that opens centred has to be waited for:
    /// the strip is in front of it until it goes away, so the first thing a hand
    /// does after asking to edit a picture is wait. Below the strip is space the
    /// panel never uses, and it is where the pointer already is.
    private func placeUnderTheLine() {
        guard let frame = underTheLineFrame() else {
            window.center()
            return
        }
        window.setFrame(frame, display: false)
    }

    /// The frame the window opens at, worked out without opening it.
    ///
    /// The strip's own frame rather than a guess at its depth: how deep it is
    /// depends on what is hanging on it at that moment.
    private func underTheLineFrame() -> NSRect? {
        guard let screen = LinePanel.screenUnderPointer() ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        let stripBottom = LinePanel.current?.frame.minY ?? (visible.maxY - Layout.clipboardDepth)
        let top = min(stripBottom, visible.maxY) - margin
        var frame = window.frame
        frame.size.width = min(frame.size.width, visible.width - margin * 2)
        // Whatever is left under the strip, and never smaller than the window is
        // allowed to be: on a screen too short for both, a window that opens at
        // its own minimum is better than one that opens half off the bottom.
        frame.size.height = max(window.minSize.height, min(frame.size.height, top - visible.minY - margin))
        frame.origin = NSPoint(x: visible.midX - frame.size.width / 2,
                               y: max(top - frame.size.height, visible.minY + margin))
        return frame
    }

    /// Harness: the frame the window would open at, without opening it.
    var previewUnderTheLineFrame: NSRect? { underTheLineFrame() }

    /// Opens a picture without showing or focusing the window.
    ///
    /// Harness support, not a feature: the window can then be rendered
    /// offscreen, which is the only way to look at a layout change on a machine
    /// whose screen nobody is watching.
    func preview(url: URL) {
        load(url: url)
    }

    /// The window, for the harness that renders it.
    var previewWindow: NSWindow { window }

    /// The picture's size in pixels, for the harness that checks a crop landed.
    var previewPixelSize: CGSize { document?.pixelSize ?? .zero }

    /// What the text tool is set to, for the harness that checks whether a press
    /// on 斜体 reached the style at all.
    var previewTextStyle: ToolStyle { style(for: .text) }

    /// Harness: zoom without a hand on the trackpad.
    func previewZoom(_ value: CGFloat?) {
        canvas.setZoom(value)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Harness: the percentage the bar is showing, as text.
    var previewZoomLabel: String { zoomLabel?.title ?? "no label" }

    /// Harness: where a point in picture pixels lands in the window.
    func previewViewPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        canvas.viewPoint(x: x, y: y)
    }

    /// Harness: the last mark's own geometry on the picture, in pixels.
    ///
    /// A shape's `bounds` is its rectangle grown by half the stroke so that a
    /// click near the edge grabs it; the rectangle the drag described is the
    /// thing a zoom can get wrong, so that is what the drill reads.
    var previewLastMark: CGRect? {
        guard let mark = document?.marks.last else { return nil }
        if let shape = mark as? ShapeMark { return shape.rect }
        return mark.bounds
    }

    /// Harness: hold the bars in the state a drag puts them in, so a still
    /// picture can show it.
    func previewFade() { fadeBars(true) }

    /// Harness: where the picture's bottom-left corner is, in the canvas.
    var previewImageOrigin: NSPoint { canvas.previewImageOrigin }

    /// Harness: how many marks are on the picture.
    var previewMarkCount: Int { document?.marks.count ?? 0 }

    /// Harness: whether the drawer is out of sight.
    var previewDrawerHidden: Bool { drawer?.isHidden ?? true }

    /// Harness: press a tool chip the way a hand would — same target, same
    /// action, same tag. A second press on the tool already in hand is a rule
    /// of its own, and it cannot be checked by calling `select`.
    func previewPressTool(_ tool: EditorTool) {
        guard let chip = toolButtons[tool] else { return }
        toolTapped(chip)
    }

    /// Harness: the letter each tool is showing in its corner, in tool order.
    ///
    /// Empty strings would read as "a tool with no key", so the list simply
    /// stops at the first tool without one — its length is the count of corners
    /// that have something in them.
    var previewShortcutHints: [String] {
        EditorTool.allCases.compactMap { toolButtons[$0]?.hint }
    }

    /// Harness: the line each corner letter is drawn on, in tool order.
    ///
    /// Eleven letters look like one row in a picture even when one of them is
    /// four points off, because at this size four points is most of the letter.
    /// The numbers have no such trouble.
    var previewHintBaselines: [CGFloat] {
        EditorTool.allCases.compactMap { toolButtons[$0]?.hintBaseline }
    }

    /// Harness: what the first slider's caption says right now.
    var previewPrimaryCaption: String { primaryLabel.stringValue }

    /// Harness: whether the sliders report while the knob is still moving.
    ///
    /// The drill below can prove that the caption follows a report; it cannot
    /// make AppKit send the reports, because that happens inside a tracking
    /// loop it would never get out of. This is the switch that decides, so it
    /// gets asserted rather than assumed.
    var previewSlidersReportWhileDragging: Bool {
        primarySlider.isContinuous && secondarySlider.isContinuous
    }

    /// Harness: one report from the first slider, as the knob moving sends it.
    ///
    /// The slider is left "in hand": the drill has to look at the caption
    /// *between* two reports, which is the whole question. `previewReleasePrimary`
    /// is the other half.
    @discardableResult
    func previewSlidePrimary(to value: Double) -> String {
        primarySlider.previewDrag(true)
        primarySlider.doubleValue = value
        primarySlider.sendAction(primarySlider.action, to: primarySlider.target)
        return primaryLabel.stringValue
    }

    /// Harness: the mouse coming up.
    func previewReleasePrimary() {
        primarySlider.previewDrag(false)
    }

    /// Harness: the three bars in content-view coordinates.
    ///
    /// They are pinned to three different anchors, so the one failure with no
    /// warning at all is a window narrow enough to slide them into each other:
    /// nothing leaves the window, and two things end up on top of each other.
    var previewBarFrames: [NSRect] {
        guard let root = window.contentView else { return [] }
        return [leftIsland, centreIsland, rightIsland].compactMap { $0 }
            .map { $0.convert($0.bounds, to: root) }
    }

    // MARK: The picture

    private func load(url: URL) {
        guard let image = EditorStore.load(url) else {
            let alert = NSAlert()
            alert.messageText = L("This picture could not be opened")
            alert.informativeText = url.lastPathComponent
            alert.runModal()
            return
        }
        // Before anything can be drawn on it. The file on disk is only known
        // to be clean right now; after the first write-back it never is again.
        EditorStore.keepBase(image, for: url)
        document = EditorDocument(source: image)
        self.url = url
        backedUp = false
        saved = true
        updateTitle()
        canvas.document = document
        canvas.selected = nil
        select(.select)
    }

    // MARK: Building

    /// The title bar is the only place the picture is named now, so the name
    /// and the size travel together: one line, one time.
    ///
    /// Rewritten whenever the picture changes size, because cropping changes it
    /// — a title still showing the size the file had when it was opened is a
    /// title that lies about the picture underneath it.
    private func updateTitle() {
        guard let url else { return }
        let name = url.lastPathComponent
        guard let document else {
            window.title = name
            return
        }
        let size = document.pixelSize
        window.title = "\(name)  ·  \(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    private func buildContent() {
        let container = NSView()
        window.contentView = container

        // The name and its size live in the title bar, together: the window
        // already says which file this is, and saying it twice — once in the
        // title, once on a banner under it — is one name too many. The size
        // moved up to join it because "is this picture wide enough for what I
        // am about to write on it" is a question about pixels, and the title is
        // now where the picture's identity is.

        undoButton = symbolButton("arrow.uturn.backward", L("Undo"), #selector(undoTapped))
        redoButton = symbolButton("arrow.uturn.forward", L("Redo"), #selector(redoTapped))

        // Two endings, as icons, at the far end of the tool row. Neither closes
        // the window: closing is the traffic lights' job, and a window that
        // disappears when you take a copy of the picture is a window you have
        // to open again to keep working.
        //
        // 覆盖 rather than 保存: this button replaces the file the picture came
        // from. A word that promises "kept somewhere" is not the truth, and the
        // difference matters exactly once — the first time.
        copyButton = ToolChip(symbol: "doc.on.doc", tip: L("Copy this version"),
                              target: self, action: #selector(copyTapped))
        writebackButton = ToolChip(symbol: "square.and.arrow.down",
                                   tip: L("Replace the original file with this version"),
                                   target: self, action: #selector(saveTapped))
        // Momentary, unlike the tools: a tool stays in the hand, an action is
        // over the moment it happens.
        copyButton.setButtonType(.momentaryPushIn)
        writebackButton.setButtonType(.momentaryPushIn)
        writebackButton.keyEquivalent = "\r"

        // Zoom, sharing the ending's bar. From here the picture is either
        // looked at closely or handed over, and both are decisions about the
        // whole picture rather than about the stroke being drawn — which is the
        // line between this bar and the middle one.
        zoomOutButton = ToolChip(symbol: "minus.magnifyingglass", tip: L("Zoom Out"),
                                 target: self, action: #selector(zoomOutTapped))
        zoomInButton = ToolChip(symbol: "plus.magnifyingglass", tip: L("Zoom In"),
                                target: self, action: #selector(zoomInTapped))
        zoomOutButton.setButtonType(.momentaryPushIn)
        zoomInButton.setButtonType(.momentaryPushIn)
        zoomLabel = NSButton(title: "100%", target: self, action: #selector(zoomMenuTapped))
        zoomLabel.isBordered = false
        zoomLabel.bezelStyle = .inline
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.toolTip = L("Zoom")
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            zoomLabel.widthAnchor.constraint(equalToConstant: 44),
            zoomLabel.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Seven colours on the shelf, one dot that opens the well for the rest.
        // A screenshot's ink is chosen in a second, and the system panel spends
        // that second asking which colour space you had in mind.
        presetDots = Self.presetColours.map { preset in
            ColourDot(colour: preset.colour, tip: L(preset.name),
                      target: self, action: #selector(presetTapped(_:)))
        }
        for (index, dot) in presetDots.enumerated() { dot.tag = index }
        customDot = ColourDot(custom: true, tip: L("More Colours"),
                              target: self, action: #selector(customTapped))

        primaryLabel = valueLabel()
        primarySlider = valueSlider(#selector(primaryChanged))
        secondaryLabel = valueLabel()
        secondarySlider = valueSlider(#selector(secondaryChanged))

        // A switch drawn as an icon, so the second row speaks one language: the
        // controls on the trays are all the same size whether they are a tool, a
        // mode, or an on/off.
        //
        // `square.inset.filled` — a frame with a filled block inside it, which
        // is what filling a shape does. It used to be `square` / `square.fill`,
        // and an empty square next to the rectangle tool's empty rectangle is
        // two icons that have to be told apart by size.
        fillToggle = ToolChip(symbol: "square.inset.filled", tip: L("Fill"),
                              target: self, action: #selector(fillChanged))
        boldButton = ToolChip(symbol: "bold", tip: L("Bold"),
                              target: self, action: #selector(boldTapped))
        italicButton = ToolChip(symbol: "italic", tip: L("Italic"),
                                target: self, action: #selector(italicTapped))

        // The crop frame's shape. It sits first on the property row while the
        // crop tool is up, where the sliders are the rest of the time — the
        // frame's shape and the stroke's width are the same kind of thing
        // (a number about the next thing you draw) and belong in the same
        // place. It used to hang off the far right on its own, which made it
        // look like a leftover.
        aspectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        aspectPopup.controlSize = .small
        aspectPopup.font = .systemFont(ofSize: 11)
        for (index, aspect) in CropAspect.allCases.enumerated() {
            aspectPopup.addItem(withTitle: aspect.title)
            // Tags rather than positions: the menu order and the enum order are
            // allowed to disagree, and a separator would otherwise shift every
            // row by one.
            aspectPopup.item(at: index)?.tag = index
        }
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChanged)
        aspectPopup.toolTip = L("Crop proportions")
        aspectPopup.translatesAutoresizingMaskIntoConstraints = false
        aspectPopup.widthAnchor.constraint(equalToConstant: 88).isActive = true

        for tool in EditorTool.allCases {
            toolButtons[tool] = toolButton(tool)
        }
        func chips(_ tools: [EditorTool]) -> [NSView] {
            tools.compactMap { toolButtons[$0] }
        }

        // The middle bar, in three groups: how the picture is being looked at
        // (the hand and the zoom), then the two tools that change nothing, then
        // the marks a hand switches between constantly.
        //
        // Zoom lives here rather than with the two endings. It used to sit at
        // the end of the right-hand bar, which left that bar holding four things
        // and the left holding two — a window that reads as heavier on one side
        // for no reason the user could act on. Two and two at the ends, and
        // everything about the picture in the middle, is a shape that balances
        // without a measurement.
        var middle: [NSView] = chips([.hand])
        middle.append(zoomOutButton)
        middle.append(zoomLabel)
        middle.append(zoomInButton)
        middle.append(EditorSeparator())
        middle += chips([.select, .crop])
        middle.append(EditorSeparator())
        middle += chips([.rectangle, .ellipse, .arrow, .pen, .highlight, .mosaic, .number, .text])

        // Fill belongs with the numbers, not with the ink: it is how the shape
        // is drawn, and the colour is what it is drawn with. It used to sit at
        // the end of the colour shelf, where a square among seven circles read
        // as an eighth colour.
        stripHint = NSTextField(labelWithString: "")
        stripHint.font = .systemFont(ofSize: 11)
        stripHint.textColor = .tertiaryLabelColor
        stripHint.lineBreakMode = .byTruncatingTail
        // A sentence gives way before a control does: the drawer is as wide as
        // what is in it, and the words are the part nobody needs in full.
        stripHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The drawer, in the order the work happens: the frame's shape (crop
        // only), then the two numbers, then the ink, then the sentence that
        // stands in for all of it when the tool has none.
        drawerSeamInk = EditorSeparator()
        drawerSeamFrame = EditorSeparator()
        var drawerRow: [NSView] = [aspectPopup]
        drawerRow.append(drawerSeamFrame)
        drawerRow.append(primaryLabel)
        drawerRow.append(primarySlider)
        drawerRow.append(secondaryLabel)
        drawerRow.append(secondarySlider)
        drawerRow.append(fillToggle)
        drawerRow.append(boldButton)
        drawerRow.append(italicButton)
        drawerRow.append(drawerSeamInk)
        for dot in presetDots { drawerRow.append(dot) }
        drawerRow.append(customDot)
        drawerRow.append(stripHint)

        let left = EditorGroup([undoButton, redoButton], spacing: 2, surface: .floating)
        let centre = EditorGroup(middle, spacing: 3, surface: .floating)
        // The two endings, on their own, at the far edge: the destructive press
        // is the furthest thing from the tools, and two buttons is all this bar
        // has to hold now that zoom has moved in with the tools.
        let right = EditorGroup([copyButton, writebackButton], spacing: 3, surface: .floating)
        let drawerView = EditorGroup(drawerRow, spacing: 6, surface: .floating)
        // Nothing to adjust on the cursor tool, which is where every picture
        // starts: the drawer is out of the way until a tool or a mark gives it
        // something to say.
        drawerView.isHidden = true

        leftIsland = left
        centreIsland = centre
        rightIsland = right
        drawer = drawerView

        // The picture fills the window, and the bars sit on top of it. Nothing
        // is carved out for them, which is the whole point: they cost the
        // picture no height at all, and a hand that is drawing towards the top
        // can see through them (they fade while a drag is in progress).
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)
        for island in [left, centre, right, drawerView] {
            container.addSubview(island)
        }

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            left.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            centre.topAnchor.constraint(equalTo: left.topAnchor),
            centre.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            drawer.topAnchor.constraint(equalTo: centre.bottomAnchor, constant: 8),
            drawer.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
    }

    private func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        // Wide enough for the longest caption there is — "不透明度 100%" — and
        // fixed, so the sliders do not step sideways as the words change from
        // "粗细 4" to "块大小 24".
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return label
    }

    private func valueSlider(_ action: Selector) -> ValueSlider {
        let slider = ValueSlider(value: 4, minValue: 1, maxValue: 40, target: self, action: action)
        slider.controlSize = .small
        // Continuously, so the number beside it moves with the knob: a slider
        // that only speaks when the mouse comes up is a slider whose value the
        // user cannot see themselves choosing. Twelve undo steps for one
        // decision is not a risk here — the document coalesces by tag, and the
        // tag is the field, so one drag is one history entry. Writing the style
        // file is what has to wait, and it waits for `onCommit`.
        slider.isContinuous = true
        slider.onCommit = { [weak self] in
            guard let self else { return }
            EditorStyleStore.save(styles)
        }
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return slider
    }

    private func symbolButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    /// Steps the bars out of the way while something is being dragged.
    ///
    /// Not because a floating bar over a picture is wrong — that is the whole
    /// design — but because the one place it is wrong is a picture tall enough
    /// to run underneath it, which is exactly the picture being annotated at the
    /// top edge. A third of the ink still shows where the bars are; the picture
    /// shows through them.
    private func fadeBars(_ active: Bool) {
        let bars: [NSView] = [leftIsland, centreIsland, rightIsland, drawer].compactMap { $0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = active ? 0.12 : 0.22
            context.allowsImplicitAnimation = true
            for bar in bars where bar.isHidden == false {
                bar.animator().alphaValue = active ? 0.32 : 1
            }
        }
    }

    /// A tool chip, with its own letter in the tooltip.
    private func toolButton(_ tool: EditorTool) -> ToolChip {
        let chip = ToolChip(image: tool.icon, tip: "\(tool.label)  \(tool.key.uppercased())",
                            target: self, action: #selector(toolTapped(_:)))
        chip.tag = EditorTool.allCases.firstIndex(of: tool) ?? 0
        return chip
    }

    /// Puts the letter keys in the corners, or takes them away.
    ///
    /// One function rather than a line in `toolButton`, because the switch can
    /// move while a window is open: the chips are built once and repainted
    /// after, and that repaint is the only way a change reaches a window that is
    /// already on screen. The letter is upper case because that is how a key is
    /// named when it is being taught, while the key actually typed is not
    /// shifted — the label says "press V", not "press shift-v".
    private func applyShortcutHints() {
        let on = ShortcutHints.isEnabled
        for (tool, chip) in toolButtons {
            chip.hint = on ? tool.key.uppercased() : nil
        }
    }

    /// Pressing a tool puts it in the hand; pressing the tool already in the
    /// hand folds the drawer away.
    ///
    /// The second press has to mean something, or the drawer has no way of being
    /// dismissed except by leaving the tool — and leaving the tool to get the
    /// picture out of the way is not a thing anyone wants to do while drawing.
    /// Only the chip folds it: the letters on the keyboard are how a tool is
    /// chosen, and pressing one for a tool already chosen must not hide the
    /// numbers it is about to need.
    @objc private func toolTapped(_ sender: NSButton) {
        let tools = EditorTool.allCases
        guard tools.indices.contains(sender.tag) else { return }
        let tool = tools[sender.tag]
        if tool == currentTool {
            drawerFolded.toggle()
            refreshControls()
            return
        }
        select(tool)
    }

    /// Puts a tool in the hand, and brings its settings back with it.
    ///
    /// Picking a tool also puts the selection down. Half a state is worse than
    /// either: with a rectangle picked out and the arrow tool up, a drag across
    /// the picture would have two plausible meanings and the wrong one wins.
    func select(_ tool: EditorTool) {
        currentTool = tool
        // A drawer folded away belongs to the tool it was folded on. Choosing
        // another tool asks to see that tool's numbers.
        drawerFolded = false
        canvas.selected = nil
        // Leaving the crop tool abandons a half-drawn crop: a frame you can no
        // longer see the handles of is a frame you would apply by accident.
        if tool != .crop, canvas.cropRect != nil { canvas.setCrop(nil) }
        for (each, chip) in toolButtons {
            chip.state = each == tool ? .on : .off
            chip.isPicked = each == tool
        }
        canvas.tool = tool
        canvas.style = style(for: tool)
        canvas.cropRatio = selectedAspect.ratio
        // The pointer is part of the answer to "what does this tool do", so it
        // changes with the tool and not one click later.
        canvas.window?.invalidateCursorRects(for: canvas)
        refreshControls()
    }

    private var selectedAspect: CropAspect {
        guard let item = aspectPopup.selectedItem,
              CropAspect.allCases.indices.contains(item.tag) else { return .free }
        return CropAspect.allCases[item.tag]
    }

    @objc private func aspectChanged() {
        canvas.cropRatio = selectedAspect.ratio
        // A frame already on the picture takes the new shape instead of
        // silently disagreeing with the popup that is sitting right there.
        canvas.reshapeCrop(to: selectedAspect.ratio)
    }

    private func style(for tool: EditorTool) -> ToolStyle {
        styles[tool] ?? tool.defaultStyle
    }

    /// Which tool drew a mark. Needed because a picked-up mark reports its own
    /// style, but the strip still has to decide which sliders apply to it.
    private func tool(for mark: EditorMark) -> EditorTool? {
        switch mark {
        case is MosaicMark: return .mosaic
        case let stroke as StrokeMark: return stroke.isHighlighter ? .highlight : .pen
        case is ArrowMark: return .arrow
        case let shape as ShapeMark: return shape.shape == .rectangle ? .rectangle : .ellipse
        case is TextMark: return .text
        case is NumberedMark: return .number
        default: return nil
        }
    }

    // MARK: The property strip

    private func selectionChanged(to mark: EditorMark?) {
        refreshControls()
    }

    /// What the drawer currently means: the picked-up mark, or the next mark
    /// the tool will draw, or nothing at all.
    ///
    /// Controls are never removed, only hidden with their width given back. A
    /// drawer that rearranges itself every time the tool changes cannot be
    /// learned, and one that moves under the pointer is worse than one with a
    /// greyed-out section.
    private func refreshControls() {
        let selected = canvas.selected
        let editing = canvas.editingText
        // With a caret open the drawer describes the words being typed: they are
        // what the next change lands on, and they are what the user is looking
        // at.
        let tool = editing != nil ? .text : (selected.flatMap { tool(for: $0) } ?? currentTool)
        let style = editing?.style ?? selected?.style ?? style(for: currentTool)

        // Colour belongs to anything that paints; the crop frame's shape belongs
        // to the crop tool, which paints nothing — and outside the crop tool
        // there is no crop frame to give a shape to.
        let cropping = (tool == .crop)
        let painting = !cropping && tool.supportsColour
        drawer.show(drawerSeamInk, painting)
        for dot in presetDots {
            drawer.show(dot, painting)
            dot.isPicked = painting && ColourDot.matches(dot.colour, style.color)
        }
        drawer.show(customDot, painting)
        // A colour from the well lands on the eighth dot: the drawer has to be
        // able to show ink that is not on the shelf.
        let borrowed = painting && presetDots.allSatisfy { !ColourDot.matches($0.colour, style.color) }
        customDot.borrowed = borrowed ? style.color : nil
        customDot.isPicked = borrowed

        drawer.show(aspectPopup, cropping)
        drawer.show(drawerSeamFrame, cropping)

        let fields = self.fields(for: tool)
        // Weight and slant are the text's alone.
        let forText = (tool == .text)

        // Nothing to adjust — the cursor tool with nothing picked, or the crop
        // tool, whose only number is the frame's shape — so the drawer says what
        // to do instead of standing there full of sliders that move nothing.
        let adjustable = fields.primary != nil || fields.secondary != nil
        drawer.show(stripHint, adjustable == false)
        stripHint.stringValue = tool == .crop
            ? L("Drag a frame on the picture, then double-click to crop")
            : L("Click a mark on the picture to change it")

        primaryField = fields.primary ?? .width
        secondaryField = fields.secondary ?? .opacity
        apply(field: primaryField, to: primarySlider, label: primaryLabel,
              enabled: fields.primary != nil, style: style, tool: tool)
        apply(field: secondaryField, to: secondarySlider, label: secondaryLabel,
              enabled: fields.secondary != nil, style: style, tool: tool)
        // One slot, one control. A slider whose tool has no second number is
        // left out rather than kept in place with a dash over it, and the two
        // letters only exist for the one tool they belong to.
        drawer.show(primaryLabel, fields.primary != nil)
        drawer.show(primarySlider, fields.primary != nil)
        drawer.show(secondaryLabel, fields.secondary != nil)
        drawer.show(secondarySlider, fields.secondary != nil)
        drawer.show(boldButton, forText)
        drawer.show(italicButton, forText)

        // Fill belongs to the two shapes that enclose an area. Left on the row
        // for the other tools it is a disabled square drawn as a square — which
        // reads as an empty slot, not as "this does not apply here".
        let fillable = (tool == .rectangle || tool == .ellipse)
        drawer.show(fillToggle, fillable)
        fillToggle.isEnabled = fillable
        fillToggle.state = style.isFilled ? .on : .off
        fillToggle.isPicked = style.isFilled && fillable

        boldButton.isEnabled = forText
        italicButton.isEnabled = forText
        boldButton.state = style.isBold ? .on : .off
        italicButton.state = style.isItalic ? .on : .off
        boldButton.isPicked = forText && style.isBold
        italicButton.isPicked = forText && style.isItalic

        aspectPopup.isEnabled = cropping

        // The drawer itself only exists when it has something to say: a picture
        // opens on the cursor tool with nothing picked, and that state has no
        // numbers at all. One folded by a second press on the tool in hand stays
        // folded until another tool is chosen.
        drawer.isHidden = drawerFolded || (adjustable == false && cropping == false && painting == false)

        refreshButtons()
    }

    /// Which two numbers this tool has to offer.
    ///
    /// Two, because the strip has two slots and the one tool that wants three
    /// (a mosaic: brush, block size) does not want a colour in between.
    private func fields(for tool: EditorTool) -> (primary: StyleField?, secondary: StyleField?) {
        switch tool {
        case .select, .hand, .crop:
            return (nil, nil)
        case .rectangle, .ellipse:
            return (.width, .opacity)
        // Opacity was reachable only for the shapes and the highlighter, though
        // every stroke understands it: a soft pen and a see-through arrow are
        // ordinary ways to point at something without burying it. A slot with a
        // real control in it beats a slot with a dash in it.
        case .arrow, .pen:
            return (.width, .opacity)
        case .highlight:
            return (.width, .opacity)
        case .mosaic:
            return (.width, .blockSize)
        case .number:
            return (.width, nil)
        case .text:
            return (.fontSize, .opacity)
        }
    }

    private func apply(field: StyleField, to slider: NSSlider, label: NSTextField,
                       enabled: Bool, style: ToolStyle, tool: EditorTool) {
        slider.isEnabled = enabled
        label.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        guard enabled else {
            label.stringValue = "—"
            return
        }
        let value = style.value(for: field)
        let range = field.range(for: tool)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = Double(value)
        label.stringValue = field.caption(value, name: name(for: field, tool: tool))
    }

    /// The strip's own word for a number, which depends on the tool: a width is
    /// a stroke's thickness for a pen and a disc's diameter for a number.
    /// Calling both "Width" would be a small lie the user has to translate.
    private func name(for field: StyleField, tool: EditorTool) -> String {
        if field == .width, tool == .number { return L("Size") }
        return field.name
    }

    // MARK: Actions

    private func refreshButtons() {
        undoButton.isEnabled = document?.canUndo ?? false
        redoButton.isEnabled = document?.canRedo ?? false
        // The button is the indicator: if there is nothing unsaved it has
        // nothing to do, and a disabled control says so better than a tooltip.
        writebackButton.isEnabled = saved == false
    }

    /// Undo and redo replace the whole array with copies, so a selection can end
    /// up naming a mark that is no longer anywhere on the picture. Dropping it
    /// is the honest answer: the clone that came back is a different object, and
    /// pretending it is the same one would mean dragging a mark the user did not
    /// pick up.
    private func pruneSelection() {
        guard let selected = canvas.selected else { return }
        guard let document, document.marks.contains(where: { $0 === selected }) else {
            canvas.selected = nil
            selectionChanged(to: nil)
            return
        }
    }

    /// A mark landed on the picture. Nothing is on disk until it is written
    /// back, so the close prompt has to know that something would be lost.
    private func pictureChanged() {
        saved = false
        // Cropping changes the size in pixels, and the title is where that
        // number lives.
        updateTitle()
        canvas.needsDisplay = true
        refreshButtons()
    }

    @objc private func undoTapped() { perform(.undo) }
    @objc private func redoTapped() { perform(.redo) }
    /// ⌘C and the copy icon do the same thing, and neither closes the window.
    @objc private func copyTapped() { perform(.copyImage) }
    @objc private func saveTapped() { perform(.save) }

    // MARK: Zoom

    /// A tenth larger, a tenth smaller. Ten points of percentage at a time, so
    /// the number in the bar is one the hand can predict.
    @objc private func zoomInTapped() { canvas.stepZoom(1) }
    @objc private func zoomOutTapped() { canvas.stepZoom(-1) }
    @objc private func zoomFitTapped() { canvas.setZoom(nil) }
    @objc private func zoomHalfTapped() { canvas.setZoom(0.5) }
    @objc private func zoomActualTapped() { canvas.setZoom(1) }
    @objc private func zoomDoubleTapped() { canvas.setZoom(2) }
    @objc private func zoomQuadrupleTapped() { canvas.setZoom(4) }

    /// The percentage opens the list of sizes worth returning to.
    ///
    /// A popup button cannot be the control here: it shows its own items, and
    /// "38%" — the size the picture happens to have been fitted to — is not one
    /// of them. So the number is a button, and the menu it drops is built each
    /// time, because the one thing in it that changes is which item is current.
    @objc private func zoomMenuTapped() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add(L("Zoom to Fit"), #selector(zoomFitTapped), "1")
        add(L("Zoom In"), #selector(zoomInTapped), "+")
        add(L("Zoom Out"), #selector(zoomOutTapped), "-")
        menu.addItem(.separator())
        add("50%", #selector(zoomHalfTapped), "")
        add("100%", #selector(zoomActualTapped), "0")
        add("200%", #selector(zoomDoubleTapped), "")
        add("400%", #selector(zoomQuadrupleTapped), "")
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: zoomLabel.bounds.height + 6), in: zoomLabel)
    }

    /// The press landed and the window is staying open, so something in the
    /// window has to say so: the glyph becomes a tick and the chip wears the
    /// same clay wash the picked tool wears, for a second.
    ///
    /// One light for one meaning. The row has no other use for "lit", so the
    /// tick borrows it rather than inventing a second vocabulary — a capsule in
    /// a different shape at the end of a row of glyphs was exactly the thing
    /// that made these two buttons look like they came from another window.
    ///
    /// Counted per button rather than with a shared `Timer`: pressing copy and
    /// then overwrite a moment later must not leave the first glyph stuck as a
    /// tick because the second press cancelled its timer.
    private func flash(_ button: ToolChip, _ symbol: String, backTo restore: String) {
        let key = ObjectIdentifier(button)
        let generation = (flashes[key] ?? 0) + 1
        flashes[key] = generation
        button.symbol(symbol)
        button.isPicked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.flashes[key] == generation else { return }
            button.symbol(restore)
            // A write leaves nothing to write, so the tick fades into a greyed
            // icon rather than into a live one.
            button.isPicked = false
            button.needsDisplay = true
        }
    }

    /// Every style change goes through here, so the two destinations stay
    /// straight: a picked-up mark takes the change, otherwise the tool does.
    /// Recolouring one arrow must not repaint every arrow drawn afterwards,
    /// which is exactly what happens if both are written.
    ///
    /// The mark being typed into is the first destination of all: it is what
    /// the user is looking at, and a size or weight chosen while the caret is
    /// open that only took effect after committing would be a change nobody
    /// could see themselves making.
    /// `persist` is false while a slider is being dragged: the style is live in
    /// the window from the first pixel of travel, but the file is only written
    /// when the hand lets go. Without that split the caption would be honest and
    /// the disk would be busy — a drag is one decision, not sixty.
    private func mutateStyle(tag: String, persist: Bool = true,
                             _ change: (inout ToolStyle) -> Void) {
        if let editing = canvas.editingText {
            var updated = editing.style
            change(&updated)
            editing.style = updated
            canvas.restyleEditor()
            // Bolding a paragraph that is already on the picture changes the
            // file; bolding one still being typed does not, yet.
            if canvas.editingTextIsCommitted {
                document?.beginEdit(tag: tag)
                pictureChanged()
            }
            refreshControls()
            return
        }
        if let mark = canvas.selected {
            document?.beginEdit(tag: tag)
            var updated = mark.style
            change(&updated)
            mark.style = updated
            refreshMosaicLayer(mark)
            pictureChanged()
            refreshControls()
            return
        }
        var updated = style(for: currentTool)
        change(&updated)
        styles[currentTool] = updated
        // Kept for the next window, not just this one: a default nobody agrees
        // with is a number the user has to correct every single time.
        if persist { EditorStyleStore.save(styles) }
        canvas.style = updated
        refreshControls()
    }

    /// A mosaic paints from a copy of the picture squared off at its block
    /// size, so changing the size has to fetch a new copy.
    private func refreshMosaicLayer(_ mark: EditorMark) {
        guard let mosaic = mark as? MosaicMark, let document else { return }
        guard let layer = document.pixelated(block: mosaic.style.blockSize) else { return }
        mosaic.layer = layer
        mosaic.pixelSize = document.pixelSize
    }

    @objc private func presetTapped(_ sender: NSButton) {
        let presets = Self.presetColours
        guard presets.indices.contains(sender.tag) else { return }
        mutateStyle(tag: "color") { $0.color = presets[sender.tag].colour }
    }

    /// The eighth dot: the well, for the colour nobody keeps on a shelf.
    ///
    /// `NSColorPanel.shared` has one target and one action for the whole
    /// process, so the editor borrows it and hands it back when the window
    /// closes. Leaving it pointed at a dead window means the next editor opens
    /// a panel that still reports to the last one.
    @objc private func customTapped() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = stripStyle.color
        panel.setTarget(self)
        panel.setAction(#selector(panelColourChanged(_:)))
        Self.panelOwner = self
        panel.orderFront(nil)
    }

    @objc private func panelColourChanged(_ sender: NSColorPanel) {
        let colour = sender.color
        mutateStyle(tag: "color") { $0.color = colour }
    }

    /// Bold and italic, as two chips rather than two keys.
    ///
    /// Applied to the words being typed, else to the text that is picked up,
    /// else to the text tool's memory — the same three destinations every other
    /// style change has. The last of them is why the chips work before the
    /// first text exists: pressing 粗 and then clicking should give bold words.
    @objc private func boldTapped() { toggleBold() }
    @objc private func italicTapped() { toggleItalic() }

    private func toggleBold() {
        tweakTextStyle { $0.isBold.toggle() }
    }

    private func toggleItalic() {
        tweakTextStyle { $0.isItalic.toggle() }
    }

    private func tweakTextStyle(_ change: (inout ToolStyle) -> Void) {
        guard canvas.editingText != nil || canvas.selected is TextMark else {
            var style = style(for: .text)
            change(&style)
            styles[.text] = style
            EditorStyleStore.save(styles)
            if currentTool == .text {
                canvas.style = style
            }
            refreshControls()
            return
        }
        mutateStyle(tag: "trait", change)
    }

    @objc private func primaryChanged(_ sender: ValueSlider) {
        let field = primaryField
        let value = CGFloat(sender.doubleValue)
        mutateStyle(tag: "style-\(field.rawValue)", persist: !sender.isBeingDragged) {
            $0.set(field, value)
        }
    }

    @objc private func secondaryChanged(_ sender: ValueSlider) {
        let field = secondaryField
        let value = CGFloat(sender.doubleValue)
        mutateStyle(tag: "style-\(field.rawValue)", persist: !sender.isBeingDragged) {
            $0.set(field, value)
        }
    }

    @objc private func fillChanged() {
        let filled = fillToggle.state == .on
        mutateStyle(tag: "fill") { $0.isFilled = filled }
    }

    // MARK: Cropping

    /// A crop rectangle was drawn, or abandoned.
    ///
    /// There is no longer a button for this: double-clicking the frame applies
    /// it, and so does Return. But Return still means 覆盖 the rest of the time,
    /// so while a frame is waiting the clay pill gives the key up and the canvas
    /// answers it.
    private func cropChanged(_ rect: CGRect?) {
        writebackButton.keyEquivalent = rect == nil ? "\r" : ""
    }

    private func applyCrop() {
        guard let document, let rect = canvas.cropRect else { return }
        if document.crop(to: rect) {
            pruneSelection()
            pictureChanged()
        }
        canvas.setCrop(nil)
    }

    private func perform(_ command: EditorCanvasView.Command) {
        guard let document else { return }
        switch command {
        case .undo:
            document.undo()
            saved = false
            pruneSelection()
            canvas.needsDisplay = true
            refreshControls()
        case .redo:
            document.redo()
            saved = false
            pruneSelection()
            canvas.needsDisplay = true
            refreshControls()
        case .copyImage:
            copyToPasteboard(document)
            flash(copyButton, "checkmark", backTo: "doc.on.doc")
        case .save:
            // Nothing to write and nothing to do: the 覆盖 icon is greyed out in
            // this state, and ⌘S behaves the same way.
            guard saved == false else { return }
            write(document)
            if saved { flash(writebackButton, "checkmark", backTo: "square.and.arrow.down") }
        case .crop:
            // Double-click or Return asked for it, which is all the confirmation
            // a frame the user just dragged out needs.
            applyCrop()
        }
    }

    private func copyToPasteboard(_ document: EditorDocument) {
        guard let image = document.flattened() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: document.pixelSize)])
    }

    private func write(_ document: EditorDocument) {
        guard let url else { return }
        guard let image = document.flattened() else { return }
        if backedUp == false {
            EditorStore.backup(url)
            backedUp = true
        }
        do {
            try EditorStore.write(image, to: url)
            saved = true
            refreshButtons()
            // The card on the line learns about the new pixels the same way it
            // did when Preview wrote them: one callback, one thumbnail.
            Markup.shared.onSaved(url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // `saved` alone, not `saved || marks.isEmpty`: a crop is a change with
        // no marks in it, and it used to slip past this guard. Closing is now
        // the only way out of the window, so the one question worth asking has
        // to be asked about every kind of change.
        guard let document, saved == false else { return true }
        let alert = NSAlert()
        alert.messageText = L("Write the changes back to this picture?")
        alert.informativeText = L("Closing now keeps the file as it was. The picture is copied aside before the first write.")
        alert.addButton(withTitle: L("Overwrite"))
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            write(document)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // The colour panel outlives this window and has one target for the whole
        // process: hand it back rather than leave it pointed at a closed editor.
        if Self.panelOwner === self {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            Self.panelOwner = nil
        }
        onClose?()
    }
}

/// Where the drawing happens.
///
/// An `NSView` rather than a SwiftUI canvas, because this one owns three things
/// SwiftUI makes awkward: the mouse in picture coordinates, the key equivalents
/// an accessory app has no main menu to route, and a redraw that must be exact
/// rather than animated.
final class EditorCanvasView: NSView, NSTextViewDelegate {
    enum Command { case undo, redo, copyImage, save, crop }

    var document: EditorDocument? { didSet { needsDisplay = true } }
    var tool: EditorTool = .select
    var style = ToolStyle()
    var onCommand: ((Command) -> Void)?
    var onChange: (() -> Void)?
    /// A tool was picked by its key. The toolbar hears the same news the
    /// button would have sent, so the two can never disagree about what is in
    /// the hand.
    var onTool: ((EditorTool) -> Void)?
    /// The mark that was clicked in the cursor mode. Nil is the ordinary state
    /// and says the strip's controls are about the next mark.
    var selected: EditorMark? { didSet { needsDisplay = true } }
    var onSelect: ((EditorMark?) -> Void)?
    /// The crop frame, in picture pixels, waiting to be applied. Nil is the
    /// ordinary state: cropping is a mode you are in for as long as a frame is
    /// on the picture, not a property of the picture.
    private(set) var cropRect: CGRect? { didSet { needsDisplay = true } }
    var onCrop: ((CGRect?) -> Void)?
    /// A drag is in progress. The window's bars use it to get out of the way of
    /// the picture, which is only a problem while something is being drawn on
    /// the part of it they cover.
    var onDragActive: ((Bool) -> Void)?
    /// The shape the crop frame is locked to, if any — width over height.
    var cropRatio: CGFloat?

    // MARK: Zoom

    /// Points per pixel, as the user asked for it. Nil is "fit the window",
    /// which is the state a picture opens in and the only one that follows a
    /// resize by itself: a fit that had been turned into a number the moment it
    /// was used would be a window that stops fitting as soon as it is dragged
    /// larger.
    private(set) var zoom: CGFloat?
    /// Where the picture has been pushed to, in points, from the middle of the
    /// view. Only means anything while zoomed past the window.
    private var pan: CGSize = .zero
    /// Whose turn it is to say what the picture is scaled to. The bar shows a
    /// percentage, and the percentage depends on the window as much as on the
    /// zoom, so the canvas is the only thing that can work it out.
    var onZoom: ((CGFloat) -> Void)?

    func setZoom(_ value: CGFloat?) {
        zoom = value.map { min(max($0, 0.05), 8) }
        // Fit forgets the pan: the picture is about to be centred by the same
        // layout that computes the scale, and a leftover offset would put it
        // somewhere the user never chose.
        if zoom == nil { pan = .zero }
        clampPan()
        carryTheCaret()
        needsDisplay = true
        reportZoom()
    }

    /// One step in or out, ten percentage points at a time.
    ///
    /// A ratio was the first try and it was the wrong kind of number: ×1.25 from
    /// a hundred gives a hundred and twenty-five, and a ladder of numbers
    /// nobody asked for. A step is a habit, and a habit is countable — from
    /// wherever the picture happens to be, one press lands on the next round
    /// ten, so the ladder reads 10, 20, 30 … and a fit at 73% steps to 80%.
    func stepZoom(_ direction: CGFloat) {
        let here = Int((scale * 100).rounded())
        let target = direction > 0
            ? (here / 10) * 10 + 10
            // From a round number the step has to leave it: 100 down to 90, not
            // to 100 again.
            : (here % 10 == 0 ? here : (here / 10) * 10) - 10
        setZoom(CGFloat(max(target, 10)) / 100)
    }

    private func reportZoom() { onZoom?(scale) }

    /// Keeps the picture from being pushed off its own ground.
    ///
    /// While it is larger than the window it may be moved by exactly the part
    /// that does not fit; while it is smaller there is nothing to move, and an
    /// offset that survived from a larger zoom would leave a small picture
    /// hanging near a corner.
    private func clampPan() {
        guard let document else { pan = .zero; return }
        let box = bounds.insetBy(dx: 24, dy: 24)
        let fit = min(box.width / max(document.pixelSize.width, 1),
                      box.height / max(document.pixelSize.height, 1))
        let factor = zoom ?? min(fit, 1)
        let slackX = max((document.pixelSize.width * factor - box.width) / 2, 0)
        let slackY = max((document.pixelSize.height * factor - box.height) / 2, 0)
        pan.width = min(max(pan.width, -slackX), slackX)
        pan.height = min(max(pan.height, -slackY), slackY)
    }

    /// The caret field is pinned to the picture, not to the view, so a zoom or
    /// a pan has to carry it along or it ends up over the wrong word.
    private func carryTheCaret() {
        if let mark = editingMark, let view = editorView {
            view.frame = overlayFrame(for: mark)
        }
    }

    /// Reshapes a frame that is already waiting, keeping its top-left corner.
    func reshapeCrop(to ratio: CGFloat?) {
        guard let rect = cropRect, let ratio, rect.width > 0 else { return }
        let bounds = CGRect(origin: .zero, size: document?.pixelSize ?? rect.size)
        var reshaped = rect
        reshaped.size.height = rect.width / ratio
        reshaped.origin.y = rect.maxY - reshaped.height
        cropRect = reshaped.intersection(bounds)
        onCrop?(cropRect)
    }

    private var draft: EditorMark?
    private var dragStart: CGPoint?
    /// Whether this drag has already taken its undo snapshot. A click that only
    /// picks a mark up is not an edit; the first pixel of movement is.
    private var dragged = false
    /// Whether the hand is pushing the picture around, and where the pointer was
    /// when it took hold.
    ///
    /// In window points rather than picture pixels: a pan is a movement of the
    /// view, and the picture's own coordinates are what is moving under it.
    private var panning = false
    private var panAnchor: NSPoint = .zero

    /// Announces a crop frame to the window, which owns the button that applies
    /// it. Every change goes through here; the drag itself only moves
    /// `cropRect`, so the button does not flicker in mid-gesture.
    func setCrop(_ rect: CGRect?) {
        cropRect = rect
        onCrop?(rect)
    }

    // MARK: Text editing

    /// The mark whose words are being typed, and the field they are being typed
    /// into. Both nil is the ordinary state.
    ///
    /// The mark stays the truth while the field edits it: `textDidChange`
    /// writes through, so the picture behind the caret updates as it is typed.
    /// The mark is skipped when drawing, because the field already shows it —
    /// draw both and every letter is printed twice, a pixel apart.
    private var editingMark: TextMark?
    private var editorView: EditorTextView?
    /// Whether this session has taken its undo snapshot yet. Typing is one
    /// edit, and the first keystroke is where it starts — an editor that pushed
    /// a step per letter would make ⌘Z useless.
    private var textEditBegun = false
    /// Whether the words were already on the picture when the caret opened.
    ///
    /// ⌘Z during a session undoes the picture, which replaces the marks with
    /// clones: the mark being typed into stops being on the picture without the
    /// session knowing. Remembering that it *was* there is what stops the
    /// commit from adding a second copy of something the user has just taken
    /// away.
    private var textWasCommitted = false

    /// Where the caret field sits, in view coordinates.
    private func overlayFrame(for mark: TextMark) -> NSRect {
        let rect = imageRect
        let size = mark.measured
        let width = max(size.width * scale, 12)
        let height = max(size.height * scale, 12)
        return NSRect(x: rect.minX + mark.topLeft.x * scale,
                      y: rect.minY + mark.topLeft.y * scale - height,
                      width: width + 6,
                      height: height + 2)
    }

    private func beginTextEditing(_ mark: TextMark) {
        endTextEditing()
        let view = EditorTextView(frame: overlayFrame(for: mark))
        view.isRichText = false
        view.drawsBackground = false
        view.isEditable = true
        view.isSelectable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // No wrapping: a line ends where the user ended it, and a frame that
        // rewrapped itself as the words grew would jump under the caret.
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.font = TextLayout.font(screenStyle(mark.style))
        view.textColor = mark.style.color
        view.alignment = mark.style.alignment
        view.string = mark.text
        view.delegate = self
        view.onEscape = { [weak self] in self?.endTextEditing() }
        addSubview(view)

        editingMark = mark
        editorView = view
        textEditBegun = false
        textWasCommitted = document?.marks.contains { $0 === mark } ?? false
        window?.makeFirstResponder(view)
        needsDisplay = true
    }

    /// A style at screen size: the field has to look like the final result, and
    /// the final result is drawn at whatever scale the window happens to be.
    private func screenStyle(_ style: ToolStyle) -> ToolStyle {
        var scaled = style
        scaled.fontSize = max(style.fontSize * scale, 1)
        return scaled
    }

    /// Harness: open the caret on an empty mark and report the font the field
    /// is using.
    ///
    /// The style drill proves the press reaches the style, and a separate probe
    /// proves the font layer turns that style into italic glyphs. What neither
    /// can see is the field the user actually types into, which is the last
    /// place an italic can go missing.
    func previewCaretFontName() -> String {
        let mark = TextMark(text: "Aa", topLeft: CGPoint(x: 120, y: 300), style: style)
        beginTextEditing(mark)
        let name = editorView?.font?.fontName ?? "no field"
        // Emptied before the session ends, so the probe does not leave a mark on
        // the picture it was measuring.
        editorView?.string = ""
        endTextEditing()
        return name
    }

    /// The text whose caret is open, if any.
    /// The window's controls write to the mark in hand; while words are being
    /// typed, the mark in hand is this one — not the selection, and not the
    /// tool's memory of the last thing typed.
    var editingText: TextMark? { editingMark }

    /// Whether the words being typed are already on the picture.
    ///
    /// A style change to committed words is a change to the file; to a draft it
    /// is not yet, and marking the picture dirty for it would put "unsaved
    /// changes" on a picture that has none.
    var editingTextIsCommitted: Bool {
        guard let mark = editingMark, let document else { return false }
        return document.marks.contains { $0 === mark }
    }

    /// Carries a style change onto the caret field.
    ///
    /// The field is what the user is looking at while typing, so a weight or
    /// size that only showed up on commit would be a change they could not see
    /// being made.
    func restyleEditor() {
        guard let mark = editingMark, let view = editorView else { return }
        let onScreen = screenStyle(mark.style)
        view.font = TextLayout.font(onScreen)
        view.textColor = mark.style.color
        view.alignment = mark.style.alignment
        view.frame = overlayFrame(for: mark)
        needsDisplay = true
    }

    /// Ends the session, keeping what was typed.
    ///
    /// Nothing typed means nothing kept: an empty mark is invisible, unpickable
    /// and would sit in the undo stack forever. A mark that was already on the
    /// picture is removed instead, which is what emptying it means.
    private func endTextEditing() {
        guard let mark = editingMark else { return }
        let typed = editorView?.string ?? ""
        editorView?.delegate = nil
        editorView?.removeFromSuperview()
        editorView = nil
        editingMark = nil
        textEditBegun = false
        draft = nil
        // Removing the first responder's view leaves the window pointing at
        // something that is no longer there; the canvas is what should answer
        // keys next.
        window?.makeFirstResponder(self)

        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let onPicture = document?.marks.contains(where: { $0 === mark }) ?? false
        let wasCommitted = textWasCommitted
        textWasCommitted = false

        if trimmed.isEmpty {
            if onPicture {
                document?.remove(mark)
                onChange?()
            }
        } else if onPicture {
            if mark.text != trimmed {
                mark.text = trimmed
                onChange?()
            }
        } else if wasCommitted {
            // Undone while the caret was open. The words are already off the
            // picture; adding them back would resurrect what ⌘Z took away, in a
            // different place in the undo stack from where it was removed.
        } else {
            mark.text = trimmed
            document?.add(mark)
            onChange?()
        }
        needsDisplay = true
        // The strip was following the caret's style while the words were being
        // typed; with the caret gone it goes back to describing the tool.
        onSelect?(nil)
    }

    func textDidChange(_ notification: Notification) {
        guard let mark = editingMark, let view = editorView else { return }
        let typed = view.string
        guard typed != mark.text else { return }
        let onPicture = document?.marks.contains(where: { $0 === mark }) ?? false
        // The snapshot goes in before the words change, or undo would restore
        // the state this keystroke just produced.
        if onPicture, textEditBegun == false {
            document?.beginEdit()
            textEditBegun = true
        }
        mark.text = typed
        view.frame = overlayFrame(for: mark)
        needsDisplay = true
        // A new mark is not on the picture yet, so it is not dirty until it is
        // committed; an existing one has just changed and the file is stale.
        if onPicture { onChange?() }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// The shape of the pointer, which is the cheapest way to say what a tool
    /// is for before anything has been drawn.
    ///
    /// Every drawing tool gets the crosshair, because the question in hand with
    /// a tool in it is "exactly where"; the cursor tool keeps the arrow, which
    /// is what moving something looks like; the hand gets an open hand, which is
    /// the one cursor everybody already reads as "push the picture"; text gets
    /// the I-beam, the one shape everybody reads as "type here".
    private var toolCursor: NSCursor {
        switch tool {
        case .select: .arrow
        case .hand: panning ? .closedHand : .openHand
        case .text: .iBeam
        default: .crosshair
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: toolCursor)
    }

    /// The picture moves whenever the window does, and the caret field is
    /// pinned to the picture rather than to the view, so it has to be carried
    /// along or it ends up floating over the wrong word.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A fit is recomputed from the new size, and a zoom that was asked for
        // keeps its scale but may no longer have room to be panned as far.
        clampPan()
        carryTheCaret()
        reportZoom()
        // The cursor rects are laid out from `bounds`, and an area is only
        // remembered once it has been claimed. The first claim can happen
        // before this view is in a window at all, so the resize is where the
        // pointer first learns what the tool in hand looks like.
        window?.invalidateCursorRects(for: self)
    }

    /// Two-finger scrolling moves the picture, once there is more of it than
    /// the window can show.
    ///
    /// The ground does not scroll: it is the desk the picture sits on, and a
    /// desk that slides around under a photograph is a way of making the
    /// photograph's edges impossible to judge.
    override func scrollWheel(with event: NSEvent) {
        guard document != nil else {
            super.scrollWheel(with: event)
            return
        }
        // A mouse wheel reports lines, a trackpad reports points. Ten lines to
        // a point is a guess, but it is the guess every AppKit app makes.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        var dx = event.scrollingDeltaX * unit
        var dy = event.scrollingDeltaY * unit
        // A wheel has no second axis, so shift turns it sideways — the same
        // bargain every scroll view makes.
        if event.modifierFlags.contains(.shift), dx == 0 {
            dx = dy
            dy = 0
        }
        let before = pan
        pan.width += dx
        // AppKit's positive delta is "content moves down", and the picture is
        // drawn from the bottom left: down is a smaller y.
        pan.height -= dy
        clampPan()
        guard pan != before else { return }
        carryTheCaret()
        needsDisplay = true
    }

    /// A pinch is a zoom, and it leaves the fit behind: the number in the bar
    /// is what the hand just chose.
    override func magnify(with event: NSEvent) {
        guard document != nil else { return }
        setZoom(scale * (1 + event.magnification))
    }

    /// Where the picture sits in the view: as large as fits, with a margin so
    /// the frame is visible against the window's own ground — or at the size
    /// the zoom says, pushed by the pan, and allowed to run past the window.
    private var imageRect: NSRect {
        guard let document, document.pixelSize.width > 0, document.pixelSize.height > 0 else { return .zero }
        let box = bounds.insetBy(dx: 24, dy: 24)
        guard box.width > 0, box.height > 0 else { return .zero }
        // Fit, but never enlarge: cropping a corner leaves a few hundred pixels,
        // and filling a thousand-point window with them is a picture of its own
        // interpolation. Enlarging past one point per pixel is a decision the
        // user makes on purpose, with a percentage that says so.
        let fit = min(box.width / document.pixelSize.width, box.height / document.pixelSize.height)
        let factor = zoom ?? min(fit, 1)
        let size = NSSize(width: document.pixelSize.width * factor, height: document.pixelSize.height * factor)
        let centre = NSPoint(x: box.midX + pan.width, y: box.midY + pan.height)
        return NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var scale: CGFloat {
        guard let document, document.pixelSize.width > 0 else { return 1 }
        return imageRect.width / document.pixelSize.width
    }

    private func imagePoint(_ point: NSPoint) -> CGPoint {
        guard let document else { return .zero }
        let rect = imageRect
        let x = (point.x - rect.minX) / max(scale, 0.0001)
        let y = (point.y - rect.minY) / max(scale, 0.0001)
        return CGPoint(x: min(max(x, 0), document.pixelSize.width),
                       y: min(max(y, 0), document.pixelSize.height))
    }

    /// Harness: the other direction, so a drill can aim at a known pixel.
    func viewPoint(x: CGFloat, y: CGFloat) -> NSPoint {
        let rect = imageRect
        return NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }

    /// Harness: where the picture sits, for a drill that pushes it around.
    var previewImageOrigin: NSPoint { imageRect.origin }

    /// The ground's texture: dots twelve points apart, a point and a half
    /// across, at a tenth of the label colour — a grid you notice only when
    /// you need it.
    ///
    /// It is there for one case, and that case is the whole reason this editor
    /// exists: a screenshot of a grey app has a grey background, and on a grey
    /// ground the picture's edges disappear. Dots outside the picture answer
    /// "where does the picture stop" without tinting the picture itself.
    ///
    /// Cached, because `NSColor(patternImage:)` re-tiles on every fill and
    /// rebuilding the tile per frame is how a texture becomes a stutter. The
    /// ink is baked into the image, so an appearance change throws it away.
    private var groundPattern: NSColor?
    private weak var groundPatternAppearance: NSAppearance?

    private func dottedGround(_ appearance: NSAppearance) -> NSColor {
        if let groundPattern, groundPatternAppearance === appearance { return groundPattern }
        let step: CGFloat = 12
        let side: CGFloat = 1.8
        let image = NSImage(size: NSSize(width: step, height: step), flipped: false) { _ in
            // A tenth was the first try and it is invisible on a white window:
            // the dots have to be dark enough to be a texture, and light enough
            // that a picture laid over them is the thing being looked at. A
            // seventh is the point where both are true.
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: NSRect(x: (step - side) / 2, y: (step - side) / 2,
                                        width: side, height: side)).fill()
            return true
        }
        let colour = NSColor(patternImage: image)
        groundPattern = colour
        groundPatternAppearance = appearance
        return colour
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        groundPattern = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        dottedGround(effectiveAppearance).setFill()
        NSBezierPath(rect: bounds).fill()
        guard let document, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        guard rect.width > 0 else { return }

        ctx.saveGState()
        ctx.interpolationQuality = .high
        // The picture floats on the ground rather than being pasted onto it: a
        // hairline alone reads as a hole cut in the window, and a white picture
        // on a pale ground has no edge at all until it is lifted.
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 18,
                      color: NSColor.black.withAlphaComponent(0.20).cgColor)
        ctx.draw(document.source, in: rect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        // One call, so the counts run over the whole list in one pass: the mark
        // being typed into is skipped rather than left out of the array, and
        // the one being drawn is appended after the marks it will sit on top of.
        // Numbering the array before splitting it is what keeps a new disc
        // labelled with the number it is about to get instead of "1" until the
        // mouse comes up.
        var drawn = document.marks
        if let draft, editingMark == nil {
            drawn.append(draft)
        }
        EditorRenderer.drawMarks(drawn, in: ctx, scale: scale, skipping: editingMark)
        ctx.restoreGState()

        drawSelection()
        drawCrop()

        // A hairline, not the separator colour: at the weight of a system
        // separator the frame competes with the picture's own edges.
        NSColor.black.withAlphaComponent(0.10).setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        frame.lineWidth = 1
        frame.stroke()
    }

    /// The dashed box round the picked-up mark.
    ///
    /// Two passes, a pale halo under a dashed accent. One pass of either alone
    /// disappears on the wrong picture — the accent vanishes into a blue
    /// screenshot and the halo into a white one — and the box is the only thing
    /// telling the user which of five arrows is about to move.
    private func drawSelection() {
        guard let selected, draft == nil else { return }
        let rect = imageRect
        let box = selected.bounds
        guard box.isNull == false, box.isEmpty == false else { return }
        let frame = NSRect(x: rect.minX + box.minX * scale,
                           y: rect.minY + box.minY * scale,
                           width: box.width * scale,
                           height: box.height * scale).insetBy(dx: -3, dy: -3)

        let halo = NSBezierPath(rect: frame)
        halo.lineWidth = 3
        NSColor.white.withAlphaComponent(0.65).setStroke()
        halo.stroke()

        let line = NSBezierPath(rect: frame)
        line.lineWidth = 1
        line.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        line.stroke()
    }

    /// The crop frame: what will be kept is what is bright, and the size in
    /// pixels sits in the corner, because that is the one number a crop is
    /// actually about.
    private func drawCrop() {
        guard tool == .crop, let crop = cropRect, crop.width >= 1, crop.height >= 1 else { return }
        let rect = imageRect
        let frame = NSRect(x: rect.minX + crop.minX * scale,
                           y: rect.minY + crop.minY * scale,
                           width: crop.width * scale,
                           height: crop.height * scale)

        // One path, two subrects, even-odd: the picture outside the frame is
        // shaded and the frame itself is cut out of the shade.
        NSColor.black.withAlphaComponent(0.45).setFill()
        let shade = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        shade.append(NSBezierPath(rect: frame))
        shade.windingRule = .evenOdd
        shade.fill()

        NSColor.white.setStroke()
        let line = NSBezierPath(rect: frame)
        line.lineWidth = 1
        line.stroke()

        let text = NSAttributedString(string: "\(Int(crop.width)) × \(Int(crop.height))",
                                      attributes: [
                                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                        .foregroundColor: NSColor.white,
                                      ])
        let size = text.size()
        // Inside the frame, at its bottom left, and lifted above the bottom edge
        // when the frame is too short to hold it.
        let origin = NSPoint(x: frame.minX + 6,
                             y: max(frame.minY + 6, frame.maxY - size.height - 6))
        let chip = NSRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
        text.draw(at: origin)
    }

    override func mouseDown(with event: NSEvent) {
        // A click anywhere else finishes the text being typed and does nothing
        // else: that click's job is "I am done", not "start again".
        if editingMark != nil {
            endTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        // The hand is the one tool that changes nothing in the picture, so
        // there is nothing to start: the drag belongs to the view from the first
        // pixel, which is what makes it work when the picture is too big to fit.
        if tool == .hand {
            dragStart = nil
            panning = true
            panAnchor = event.locationInWindow
            NSCursor.closedHand.set()
            return
        }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        dragStart = point
        draft = nil
        dragged = false
        guard let document else { return }
        guard tool != .select else {
            if event.clickCount == 2, let text = mark(at: point, in: document) as? TextMark {
                beginTextEditing(text)
                return
            }
            pick(at: point)
            return
        }
        // Cropping reads the mouse here: a double-click on the frame is the
        // whole confirmation. A single click that never moves leaves the frame
        // alone, so looking at the picture does not throw away the crop you drew
        // a moment ago.
        if tool == .crop {
            if event.clickCount == 2, cropRect != nil { onCommand?(.crop) }
            return
        }
        if selected != nil {
            selected = nil
            onSelect?(nil)
        }
        if tool == .text {
            // Not on the picture until there is something to see: an empty
            // mark would be invisible, unpickable, and in the undo stack.
            let mark = TextMark(text: "", topLeft: point, style: style)
            draft = mark
            beginTextEditing(mark)
            return
        }
        switch tool {
        case .rectangle, .ellipse:
            draft = ShapeMark(shape: tool == .ellipse ? .ellipse : .rectangle,
                              rect: CGRect(origin: point, size: .zero), style: style)
        case .arrow:
            draft = ArrowMark(start: point, end: point, style: style)
        case .pen, .highlight:
            draft = StrokeMark(points: [point], style: style, isHighlighter: tool == .highlight)
        case .mosaic:
            guard let layer = document.pixelated(block: style.blockSize) else { return }
            draft = MosaicMark(points: [point], style: style, layer: layer, pixelSize: document.pixelSize)
        case .number:
            // Placed on the press, not dragged out: a numbered dot is a dot.
            draft = NumberedMark(center: point, style: style)
        case .select, .hand, .crop, .text:
            break
        }
        needsDisplay = true
    }

    /// Top down, because the newest mark is the one on top: click where two
    /// arrows cross and the one drawn last is the one you meant.
    ///
    /// The slack is in screen points converted to picture pixels. Six pixels of
    /// forgiveness on screen stays six whatever the zoom, which is what the hand
    /// is judging; a slack in picture pixels would be untouchable on a 5000-pixel
    /// screenshot shrunk to fit the window.
    private func mark(at point: CGPoint, in document: EditorDocument) -> EditorMark? {
        let slack = 6 / max(scale, 0.0001)
        return document.marks.last { $0.hitTest(point, slack: slack) }
    }

    private func pick(at point: CGPoint) {
        guard let document else { return }
        let hit = mark(at: point, in: document)
        if hit !== selected {
            selected = hit
            onSelect?(hit)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard editingMark == nil else { return }
        if panning {
            onDragActive?(true)
            let now = event.locationInWindow
            pan.width += now.x - panAnchor.x
            pan.height += now.y - panAnchor.y
            panAnchor = now
            clampPan()
            carryTheCaret()
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        // A click never gets here; a drag does. That is exactly the distinction
        // the bars care about — a blink on every click would be worse than the
        // overlap they are avoiding.
        onDragActive?(true)
        let point = imagePoint(convert(event.locationInWindow, from: nil))

        if tool == .crop {
            cropRect = cropBox(from: start, to: point)
            dragged = true
            needsDisplay = true
            return
        }

        if tool == .select {
            guard let selected else { return }
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            guard delta != .zero else { return }
            // One snapshot for the whole drag, taken before the first pixel
            // moves. A click that selected without moving never gets here, so
            // looking around does not fill the undo stack with nothing.
            if dragged == false {
                document?.beginEdit()
                dragged = true
                // Something is in the hand now. The arrow says "there is
                // nothing under the pointer to hold"; this says there is.
                NSCursor.closedHand.set()
            }
            selected.translated(by: delta)
            dragStart = point
            needsDisplay = true
            return
        }

        switch draft {
        case let shape as ShapeMark:
            shape.rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                width: abs(point.x - start.x), height: abs(point.y - start.y))
        case let arrow as ArrowMark:
            arrow.end = point
        case let stroke as PointsMark:
            // A mouse reports far more positions than the curve needs, and one
            // point per report makes a 4K picture's stroke into thousands of
            // quadratics. Half a point on screen is below what a hand can feel
            // and well below what the eye can see.
            if let last = stroke.points.last,
               hypot(point.x - last.x, point.y - last.y) * scale < 0.5 { return }
            stroke.points.append(point)
        default:
            return
        }
        needsDisplay = true
    }

    /// The crop frame a drag describes, anchored at the corner it started from.
    ///
    /// With a ratio set the height follows the width rather than the pointer:
    /// the pointer decides one number, the lock decides the other. Anchoring at
    /// the start corner is what lets a frame be dragged out in any direction and
    /// still grow away from the point the user pressed.
    private func cropBox(from start: CGPoint, to point: CGPoint) -> CGRect {
        let dx = point.x - start.x
        let dy = point.y - start.y
        let width = abs(dx)
        var height = abs(dy)
        if let ratio = cropRatio, ratio > 0 {
            height = width / ratio
        }
        let box = CGRect(x: dx < 0 ? start.x - width : start.x,
                         y: dy < 0 ? start.y - height : start.y,
                         width: width, height: height)
        guard let document else { return box }
        return box.intersection(CGRect(origin: .zero, size: document.pixelSize))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if panning {
            panning = false
            // Letting go puts the picture down, and the pointer says so at once:
            // waiting for the next mouse move leaves a closed hand over a
            // picture it is no longer holding.
            toolCursor.set()
            window?.invalidateCursorRects(for: self)
            onDragActive?(false)
            return
        }
        onDragActive?(false)
        if tool == .crop {
            let moved = dragged
            dragged = false
            guard moved else { return }
            // A frame under eight pixels is a slip of the hand, not a crop; it
            // is thrown away rather than offered as "keep 3 × 2 of this".
            if let crop = cropRect, crop.width >= 8, crop.height >= 8 {
                onCrop?(crop)
            } else {
                setCrop(nil)
            }
            return
        }
        if tool == .select {
            let moved = dragged
            dragged = false
            // Letting go puts the mark down, and the pointer has to say so at
            // once — waiting for the next mouse move leaves a closed hand
            // hovering over a picture it is no longer holding.
            toolCursor.set()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            if moved { onChange?() }
            return
        }
        defer {
            draft = nil
            needsDisplay = true
        }
        guard let document, let mark = draft, isWorthKeeping(mark) else { return }
        document.add(mark)
        onChange?()
    }

    /// A click that moved two pixels is not a mark, it is a slip of the hand.
    /// Each tool has its own idea of too small: a box needs both sides, an
    /// arrow needs a direction, a dot is a dot.
    private func isWorthKeeping(_ mark: EditorMark) -> Bool {
        switch mark {
        case let shape as ShapeMark:
            return shape.rect.width >= 3 && shape.rect.height >= 3
        case let arrow as ArrowMark:
            return hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y) >= 3
        case let stroke as PointsMark:
            return stroke.points.isEmpty == false
        case is NumberedMark:
            return true
        default:
            return false
        }
    }

    /// V, R, O, A, P, H, M, N, T, C, and the two keys that act on a mark rather
    /// than a tool.
    ///
    /// Plain keys, so they belong in `keyDown`; the command key is answered in
    /// `performKeyEquivalent`, because an accessory app has no main menu to
    /// route either one.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:   // delete, forward delete
            if let selected, let document = document {
                document.remove(selected)
                self.selected = nil
                onSelect?(nil)
                onChange?()
                return
            }
        case 53:        // escape
            // The frame first: it is the more recent decision, and the one
            // sitting on top of the picture.
            if cropRect != nil {
                setCrop(nil)
                return
            }
            if selected != nil {
                selected = nil
                onSelect?(nil)
                return
            }
        case 36, 76:    // return, enter
            // While a frame is waiting the obvious meaning of the key is "apply
            // this". The 完成 pill gives the key up for exactly that long, so
            // this only sees the case where there is something to apply.
            if cropRect != nil {
                onCommand?(.crop)
                return
            }
        default:
            break
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = EditorTool.allCases.first(where: { $0.key == key }) {
            onTool?(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "z":
            onCommand?(event.modifierFlags.contains(.shift) ? .redo : .undo)
            return true
        case "c":
            onCommand?(.copyImage)
            return true
        case "s":
            onCommand?(.save)
            return true
        case "w":
            window?.performClose(nil)
            return true
        // The four keys every picture viewer uses, in that order: in, out,
        // back to one point per pixel, back to fitting the window. "=" and "+"
        // are the same key on most layouts, so both are taken.
        case "+", "=":
            stepZoom(1)
            return true
        case "-":
            stepZoom(-1)
            return true
        case "0":
            setZoom(1)
            return true
        case "1":
            setZoom(nil)
            return true
        case "\r":
            onCommand?(cropRect != nil ? .crop : .save)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
