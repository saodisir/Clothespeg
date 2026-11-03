import AppKit
import CoreText

/// A piece of type sitting on the picture.
///
/// The text is a mark like any other: it is drawn by the same renderer for the
/// screen and for the file, it can be picked up and moved, and it carries its
/// own style. What makes it different is that it has an editing life — a caret,
/// a selection, a cursor blinking inside the picture — and that life belongs to
/// a real `NSTextView` laid over the canvas, not to anything drawn here.
///
/// `topLeft` rather than an origin-plus-size: text grows down and to the right
/// from where you click, so the one point worth storing is the top-left corner.
/// The frame is derived from the measured text, which is also what keeps the
/// selection box and the hit test honest when the words change.
final class TextMark: EditorMark {
    var style: ToolStyle
    var topLeft: CGPoint
    var text: String

    init(text: String, topLeft: CGPoint, style: ToolStyle) {
        self.text = text
        self.topLeft = topLeft
        self.style = style
    }

    /// The space the words take at this style, in picture pixels.
    var measured: CGSize { TextLayout.size(text, style: style) }

    var frame: CGRect {
        let size = measured
        return CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    var bounds: CGRect { frame }

    func draw(in ctx: CGContext) {
        TextLayout.draw(text, style: style, in: frame, in: ctx)
    }

    func hitTest(_ point: CGPoint, slack: CGFloat) -> Bool {
        frame.insetBy(dx: -slack, dy: -slack).contains(point)
    }

    func translated(by delta: CGSize) {
        topLeft = CGPoint(x: topLeft.x + delta.width, y: topLeft.y + delta.height)
    }

    func clone() -> EditorMark {
        TextMark(text: text, topLeft: topLeft, style: style)
    }
}

/// One attributed string, measured and drawn the same way.
///
/// The measurement and the drawing have to come from the same attributed
/// string, or the overlay and the committed mark disagree by a few points and
/// the text jumps the moment it is committed. Core Text rather than
/// `NSAttributedString.draw`: it works in the picture's own bottom-up
/// coordinates without a flip, and it is the same call in both places.
enum TextLayout {
    static func font(_ style: ToolStyle) -> NSFont {
        var font = NSFont.systemFont(ofSize: max(style.fontSize, 1))
        let manager = NSFontManager.shared
        if style.isBold {
            font = manager.convert(font, toHaveTrait: .boldFontMask)
        }
        if style.isItalic {
            font = manager.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func attributed(_ text: String, style: ToolStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font(style),
            .foregroundColor: style.color.withAlphaComponent(style.opacity),
            .paragraphStyle: paragraph,
        ])
    }

    /// How much space the words take. A hair of width is added because the
    /// suggested size rounds down and clips the last glyph of a wide letter.
    static func size(_ text: String, style: ToolStyle) -> CGSize {
        let sample = text.isEmpty ? " " : text
        let string = attributed(sample, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let limit = CGSize(width: CGFloat.greatestFiniteMagnitude,
                           height: CGFloat.greatestFiniteMagnitude)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, limit, nil)
        return CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height))
    }

    /// Draws into a rectangle in picture space, first line at the top — which
    /// is how a frame setter lays lines out in a bottom-up context.
    static func draw(_ text: String, style: ToolStyle, in rect: CGRect, in ctx: CGContext) {
        guard text.isEmpty == false, rect.width > 0, rect.height > 0 else { return }
        let string = attributed(text, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

/// The caret you type into.
///
/// A real `NSTextView` rather than a field drawn by hand: selection, undo, IME
/// candidate windows and the system's own key handling all come for free, and
/// all of them would have to be rebuilt badly otherwise.
final class EditorTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
