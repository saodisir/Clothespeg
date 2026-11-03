import AppKit
import CoreText

/// Which tool is in the hand.
///
/// The order is the toolbar's order, left to right, and the single-key
/// shortcuts follow it: V, G, R, O, A, P, H, M, N, T, C. Letters rather than
/// numbers because the hand is already on the picture and the letters are what
/// the tools are called — a number has to be remembered, a letter is read off
/// the symbol.
///
/// The cursor comes first and is the one the editor opens with: a window that
/// starts ready to draw puts a rectangle on the picture for every click that
/// was meant to be a look.
enum EditorTool: String, CaseIterable {
    case select, hand, rectangle, ellipse, arrow, pen, highlight, mosaic, number, text, crop

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        // The one tool that moves nothing but the view. It sits beside the
        // cursor because both are "point at the picture, change nothing in it",
        // and because a zoomed picture with no way to push it around is a
        // picture you can only look at the middle of.
        case .hand: "hand.raised"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        // A nib rather than a pencil. The pencil and the highlighter are both
        // thin diagonal objects at 17 points, and a toolbar where two of its
        // nine icons have to be told apart by length is a toolbar with eight
        // icons. The nib also says what the tool does — a line — better than
        // the pencil's body did.
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        // Round dots rather than little squares: the tool blurs the picture
        // into blocks, and at 17 points a grid of squares reads as "table".
        case .mosaic: "circle.grid.3x3.fill"
        case .number: "1.circle"
        // Never looked up: every symbol in the character family draws as a
        // Chinese word inside a bundle that ships zh-Hans. See `EditorInk.textGlyph`.
        case .text: "character.cursor.ibeam"
        case .crop: "crop"
        }
    }

    /// What the toolbar draws. One tool's mark is drawn rather than found.
    var icon: NSImage? {
        self == .text
            ? EditorInk.textGlyph()
            : NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    var label: String {
        switch self {
        case .select: L("Select")
        case .hand: L("Move")
        case .rectangle: L("Rectangle")
        case .ellipse: L("Ellipse")
        case .arrow: L("Arrow")
        case .pen: L("Pen")
        case .highlight: L("Highlighter")
        case .mosaic: L("Mosaic")
        case .number: L("Number")
        case .text: L("Text")
        case .crop: L("Crop")
        }
    }

    /// The key that picks this tool while the canvas has the focus.
    var key: String {
        switch self {
        case .select: "v"
        // G for grab. H is the highlighter's and has been for as long as the
        // highlighter has existed; a tool added later does not get to move an
        // older one's letter.
        case .hand: "g"
        case .rectangle: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .pen: "p"
        case .highlight: "h"
        case .mosaic: "m"
        case .number: "n"
        case .text: "t"
        case .crop: "c"
        }
    }

    /// Whether the tool is a stroke of some kind, which is the difference
    /// between "drag a box" and "draw a line through space".
    var isStroke: Bool { self == .pen || self == .highlight }

    /// Whether the tool draws a box that can be filled.
    var isFrame: Bool { self == .rectangle || self == .ellipse }
}

/// One mark on a picture, kept in the picture's own pixels.
///
/// The coordinates are why this is a protocol with a `draw(in:)` rather than a
/// struct with a rendered result: every mark is drawn twice, once onto the
/// screen at whatever scale the window happens to be and once onto the exported
/// bitmap at scale 1. Both go through the same code. Give the screen its own
/// drawing and the export becomes a second implementation of the same picture,
/// and the two drift apart at the first arrowhead — the preview says one thing,
/// the file says another.
///
/// Pixels rather than points is deliberate too. A screenshot is a picture of
/// pixels, a Retina window shows two of them per point, and the only place
/// that difference should be known is the canvas that does the scaling.
///
/// A mark is a class, so it can be dragged in place — which is exactly why it
/// has to be able to copy itself. The undo stack holds whole arrays, and an
/// array of references to the same objects is not a past state: move a mark and
/// every snapshot moves with it. `clone()` is what makes the snapshot a past
/// state rather than a second view of the present.
protocol EditorMark: AnyObject {
    /// Everything the mark was drawn with. A mark owns its own copy, so
    /// recolouring the next stroke never reaches back and repaints this one.
    var style: ToolStyle { get set }
    /// What a selection box would go round, in picture pixels.
    var bounds: CGRect { get }
    func draw(in ctx: CGContext)
    /// Whether a click at `point` is on this mark, with `slack` pixels of
    /// forgiveness either side — a one-pixel line is impossible to hit.
    func hitTest(_ point: CGPoint, slack: CGFloat) -> Bool
    /// Moves the whole mark, for the drag that picks it up.
    func translated(by delta: CGSize)
    func clone() -> EditorMark
}

extension EditorMark {
    /// The two fields nearly every mark has, so callers do not reach through
    /// `style` for the common case.
    var color: NSColor {
        get { style.color }
        set { style.color = newValue }
    }

    var width: CGFloat {
        get { style.width }
        set { style.width = newValue }
    }
}

/// Core Graphics wants a resolved colour. A dynamic one — the accent, a system
/// colour that changes with the appearance — has no `cgColor` until it is
/// resolved in a space, so it is resolved at the drawing call rather than
/// stored. That is what lets a mark drawn in light mode survive into a dark one.
private func strokeColor(_ color: NSColor, alpha: CGFloat = 1) -> CGColor {
    let resolved = color.usingColorSpace(.sRGB) ?? NSColor.black
    return resolved.withAlphaComponent(resolved.alphaComponent * alpha).cgColor
}

/// The box points occupy, widened by half the stroke at each side: a
/// selection box drawn through the middle of a fat line looks like an error.
private func boundsOfPoints(_ points: [CGPoint], width: CGFloat) -> CGRect {
    guard let first = points.first else { return .zero }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for point in points {
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    let inset = width / 2
    return CGRect(x: minX - inset, y: minY - inset,
                  width: maxX - minX + width, height: maxY - minY + width)
}

// MARK: - Frames

/// A rectangle or an ellipse. One class, because the only difference is which
/// path gets built — the outline, the fill, the hit test and the move are the
/// same act on the same box.
final class ShapeMark: EditorMark {
    enum Shape { case rectangle, ellipse }

    var style: ToolStyle
    var rect: CGRect
    let shape: Shape

    init(shape: Shape, rect: CGRect, style: ToolStyle) {
        self.shape = shape
        self.rect = rect
        self.style = style
    }

    var bounds: CGRect {
        style.isFilled ? rect : rect.insetBy(dx: -style.width / 2, dy: -style.width / 2)
    }

    private func path() -> CGPath? {
        switch shape {
        case .rectangle: return CGPath(rect: rect, transform: nil)
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        }
    }

    func draw(in ctx: CGContext) {
        guard rect.width >= 1, rect.height >= 1, let path = path() else { return }
        ctx.saveGState()
        if style.isFilled {
            ctx.setFillColor(strokeColor(style.color, alpha: style.opacity))
            ctx.addPath(path)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(strokeColor(style.color, alpha: style.opacity))
            ctx.setLineWidth(style.width)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// On the outline, not inside it — unless it is filled, in which case the
    /// inside is paint and a click there is a click on the mark.
    ///
    /// The outline rule is what keeps a frame drawn around a paragraph from
    /// swallowing every click inside it, which would make the marks underneath
    /// impossible to pick up again.
    func hitTest(_ point: CGPoint, slack: CGFloat) -> Bool {
        if style.isFilled {
            switch shape {
            case .rectangle:
                return rect.contains(point)
            case .ellipse:
                let rx = rect.width / 2, ry = rect.height / 2
                guard rx > 0, ry > 0 else { return false }
                let dx = (point.x - rect.midX) / rx
                let dy = (point.y - rect.midY) / ry
                return dx * dx + dy * dy <= 1
            }
        }
        let outer = rect.insetBy(dx: -style.width / 2 - slack, dy: -style.width / 2 - slack)
        guard outer.contains(point) else { return false }
        let inner = rect.insetBy(dx: style.width / 2 + slack, dy: style.width / 2 + slack)
        guard inner.width > 0, inner.height > 0 else { return true }
        return inner.contains(point) == false
    }

    func translated(by delta: CGSize) {
        rect = rect.offsetBy(dx: delta.width, dy: delta.height)
    }

    func clone() -> EditorMark {
        ShapeMark(shape: shape, rect: rect, style: style)
    }
}

// MARK: - Numbered circle

/// A numbered disc, for the "step 1, step 2" that a screenshot of a form or a
/// menu usually needs.
///
/// The number is not stored on the mark: it is counted at drawing time from the
/// marks themselves, so deleting the second of four renumbers the rest instead
/// of leaving a gap somebody has to fix by hand. The export runs the same
/// renderer, so it counts the same way for free.
final class NumberedMark: EditorMark {
    var style: ToolStyle
    var center: CGPoint
    /// Filled in by the renderer on every draw. Never read before that.
    var number: Int = 1

    init(center: CGPoint, style: ToolStyle) {
        self.center = center
        self.style = style
    }

    private var radius: CGFloat { max(style.width / 2, 4) }

    var bounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(strokeColor(style.color, alpha: style.opacity))
        ctx.fillEllipse(in: bounds)

        // A digit big enough to read at a glance, in whichever of black or
        // white survives on the fill.
        let limit = radius * 1.7
        func line(size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: contrastInk(for: style.color),
            ]))
        }
        // Ten and up are two glyphs where one was expected, and a disc wide
        // enough for "8" splits "10" at the rim. Shrinking to fit keeps every
        // disc the size the user asked for instead of growing them all to suit
        // the tenth one.
        var candidate = line(size: radius * 1.45)
        var text = CTLineGetBoundsWithOptions(candidate, .useOpticalBounds)
        if text.width > limit {
            candidate = line(size: radius * 1.45 * limit / text.width)
            text = CTLineGetBoundsWithOptions(candidate, .useOpticalBounds)
        }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: center.x - text.width / 2 - text.minX,
                                   y: center.y - text.height / 2 - text.minY)
        CTLineDraw(candidate, ctx)
        ctx.restoreGState()
    }

    func hitTest(_ point: CGPoint, slack: CGFloat) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius + slack
    }

    func translated(by delta: CGSize) {
        center = CGPoint(x: center.x + delta.width, y: center.y + delta.height)
    }

    func clone() -> EditorMark {
        NumberedMark(center: center, style: style)
    }
}

/// Black or white, whichever survives on this fill. A white digit on a yellow
/// disc is not a number, it is a smudge.
///
/// Shared rather than private because a colour dot's plus sign has the same
/// problem: on the yellow swatch it has to be dark, on the blue one light.
func contrastInk(for color: NSColor) -> NSColor {
    guard let resolved = color.usingColorSpace(.sRGB) else { return .white }
    let luminance = 0.299 * resolved.redComponent
        + 0.587 * resolved.greenComponent
        + 0.114 * resolved.blueComponent
    return luminance > 0.65 ? .black : .white
}

// MARK: - Arrow

/// A straight arrow, filled head.
///
/// The head's length comes from the arrow's own length rather than a fixed
/// number, but it is floored by the stroke width: a head thinner than three
/// strokes is not a head, it is a slightly uneven end of a line, which is how
/// this arrow first looked on a 1600-pixel screenshot. Fixed sizes produce the
/// other failure mode everyone has seen — a long arrow with a pinhead — so the
/// length term is a fraction of the arrow, and the whole thing is capped at
/// half of it so a short arrow does not become all head.
final class ArrowMark: EditorMark {
    var style: ToolStyle
    var start: CGPoint
    var end: CGPoint

    init(start: CGPoint, end: CGPoint, style: ToolStyle) {
        self.start = start
        self.end = end
        self.style = style
    }

    /// How far back from the tip the head reaches.
    private var headLength: CGFloat {
        let span = hypot(end.x - start.x, end.y - start.y)
        let wanted = max(span / 4.5, style.width * 3.5)
        return min(wanted, min(style.width * 6, span * 0.45))
    }

    var bounds: CGRect {
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        return box.insetBy(dx: -max(style.width, headLength) / 2, dy: -max(style.width, headLength) / 2)
    }

    func draw(in ctx: CGContext) {
        let span = hypot(end.x - start.x, end.y - start.y)
        guard span >= 1 else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = headLength
        // The body stops inside the head instead of running to the tip: a
        // round cap on a stroke that reaches the point pokes out of the
        // triangle on both sides, and the arrow reads as a lollipop.
        let shaftEnd = CGPoint(x: end.x - cos(angle) * head * 0.75,
                               y: end.y - sin(angle) * head * 0.75)

        let paint = strokeColor(style.color, alpha: style.opacity)
        ctx.saveGState()
        ctx.setStrokeColor(paint)
        ctx.setFillColor(paint)
        ctx.setLineWidth(style.width)
        ctx.setLineCap(.round)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        // A little wider than it was, now that the head has some length to
        // carry: a long thin triangle reads as a spear.
        let spread: CGFloat = 0.52   // about 30° either side of the body
        let left = CGPoint(x: end.x - cos(angle - spread) * head,
                           y: end.y - sin(angle - spread) * head)
        let right = CGPoint(x: end.x - cos(angle + spread) * head,
                            y: end.y - sin(angle + spread) * head)
        ctx.move(to: end)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    func hitTest(_ point: CGPoint, slack: CGFloat) -> Bool {
        EditorGeometry.distance(from: point, toSegment: start, end) <= style.width / 2 + slack
    }

    func translated(by delta: CGSize) {
        start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
    }

    func clone() -> EditorMark {
        ArrowMark(start: start, end: end, style: style)
    }
}

// MARK: - Freehand strokes

/// A mark made of sampled points.
///
/// The pen, the highlighter and the mosaic brush are the same act — drag along
/// the picture and it changes under the drag — so they share the sampling, the
/// smoothing and the hit test, and differ only in what gets painted once the
/// path exists.
///
/// The curve is quadratic through the midpoints of the samples, which is the
/// cheapest smoothing that does not look like a polyline: each raw point
/// becomes a control point and each midpoint an endpoint, so the line passes
/// through none of the jitter of the mouse and all of its direction.
class PointsMark: EditorMark {
    var style: ToolStyle
    var points: [CGPoint]

    init(points: [CGPoint], style: ToolStyle) {
        self.points = points
        self.style = style
    }

    var bounds: CGRect { boundsOfPoints(points, width: style.width) }

    /// The stroke as one path. Nil for a click rather than a drag — a single
    /// point has no direction, and each tool decides what a dot means.
    func smoothedPath() -> CGPath? {
        guard let first = points.first, points.count > 1 else { return nil }
        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for index in 1..<(points.count - 1) {
                let current = points[index]
                let next = points[index + 1]
                let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
                path.addQuadCurve(to: mid, control: current)
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    func draw(in ctx: CGContext) {}

    func hitTest(_ point: CGPoint, slack: CGFloat) -> Bool {
        guard points.count > 1 else {
            guard let only = points.first else { return false }
            return hypot(point.x - only.x, point.y - only.y) <= style.width / 2 + slack
        }
        let tolerance = style.width / 2 + slack
        for index in 0..<(points.count - 1) {
            if EditorGeometry.distance(from: point, toSegment: points[index], points[index + 1]) <= tolerance {
                return true
            }
        }
        return false
    }

    func translated(by delta: CGSize) {
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }

    func clone() -> EditorMark { fatalError("PointsMark is abstract") }

    /// A dot of the stroke's own width, for the click that was a click.
    func dot(at point: CGPoint) -> CGRect {
        let r = style.width / 2
        return CGRect(x: point.x - r, y: point.y - r, width: style.width, height: style.width)
    }
}

/// The pen, and the highlighter that is the same stroke with different manners.
final class StrokeMark: PointsMark {
    var isHighlighter: Bool

    init(points: [CGPoint], style: ToolStyle, isHighlighter: Bool) {
        self.isHighlighter = isHighlighter
        super.init(points: points, style: style)
    }

    override func draw(in ctx: CGContext) {
        guard let first = points.first else { return }
        let paint = strokeColor(style.color, alpha: style.opacity)
        ctx.saveGState()
        ctx.setStrokeColor(paint)
        ctx.setLineWidth(style.width)
        ctx.setLineCap(isHighlighter ? .square : .round)
        ctx.setLineJoin(isHighlighter ? .bevel : .round)

        guard let path = smoothedPath() else {
            ctx.setFillColor(paint)
            ctx.fillEllipse(in: dot(at: first))
            ctx.restoreGState()
            return
        }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    override func clone() -> EditorMark {
        StrokeMark(points: points, style: style, isHighlighter: isHighlighter)
    }
}

/// The mosaic, painted as a brush over a layer of the picture that has already
/// been reduced to blocks.
///
/// The layer is made per block size, not per stroke: reducing a 5000-pixel
/// screenshot per mouse move would cost more than every other tool together.
/// The stroke's own path is widened into an outline and used as a clip, which
/// is what makes the brush have a shape instead of being a rectangle someone
/// dragged.
final class MosaicMark: PointsMark {
    /// A copy of the picture, already squared off at this mark's block size.
    /// Swapped when the block size changes and when the picture is cropped.
    var layer: CGImage
    /// The size the layer is stretched to, which is the picture's size.
    var pixelSize: CGSize

    init(points: [CGPoint], style: ToolStyle, layer: CGImage, pixelSize: CGSize) {
        self.layer = layer
        self.pixelSize = pixelSize
        super.init(points: points, style: style)
    }

    override func draw(in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none

        guard let path = smoothedPath() else {
            ctx.addEllipse(in: dot(at: first))
            ctx.clip()
            ctx.draw(layer, in: CGRect(origin: .zero, size: pixelSize))
            ctx.restoreGState()
            return
        }
        ctx.addPath(path)
        ctx.setLineWidth(style.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.draw(layer, in: CGRect(origin: .zero, size: pixelSize))
        ctx.restoreGState()
    }

    /// The layer is shared rather than copied: it is a picture of the source,
    /// immutable for the life of the document, and a copy per undo snapshot
    /// would be twenty megabytes a step.
    override func clone() -> EditorMark {
        MosaicMark(points: points, style: style, layer: layer, pixelSize: pixelSize)
    }
}

/// The measurements marks need.
///
/// Kept out of the marks themselves so that the selection asks the same
/// question of every mark in the same way.
enum EditorGeometry {
    /// Distance from a point to a line segment, not to the infinite line: a
    /// click past the end of an arrow is past the arrow.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}
