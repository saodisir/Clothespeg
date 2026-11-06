import AppKit

/// What a tool remembers between strokes.
///
/// One struct rather than seven sets of property fields, because the property
/// strip is one strip: it reads a style, shows what applies, writes it back.
/// A tool that ignores a field — a rectangle has no font size — simply never
/// looks at it, which is cheaper than three protocols and a per-type switch in
/// every control.
///
/// The values live two places with the same shape: a dictionary of "what the
/// next stroke will use", and each mark's own copy of what it *was* drawn with.
/// That is what makes recolouring one arrow stop repainting the next one.
struct ToolStyle: Equatable {
    var color: NSColor = .systemRed
    /// Line width, or the diameter of a brush.
    var width: CGFloat = 4
    /// Only the highlighter and a filled shape use it.
    var opacity: CGFloat = 1
    /// Text only.
    var fontSize: CGFloat = 16
    /// Mosaic only: how many picture pixels one block covers.
    var blockSize: CGFloat = 16
    /// Filled shapes: rectangle and ellipse.
    var isFilled: Bool = false
    var isBold: Bool = false
    var isItalic: Bool = false
    var alignment: NSTextAlignment = .left

    func value(for field: StyleField) -> CGFloat {
        switch field {
        // A colour tag's size is a multiplier, not a thickness. Borrowing
        // `width` keeps one stored field, so nothing already in UserDefaults
        // needs migrating and undo carries the size with the mark's style.
        case .width, .tagScale: width
        case .fontSize: fontSize
        case .blockSize: blockSize
        case .opacity: opacity
        }
    }

    mutating func set(_ field: StyleField, _ value: CGFloat) {
        switch field {
        case .width, .tagScale: width = value
        case .fontSize: fontSize = value
        case .blockSize: blockSize = value
        case .opacity: opacity = value
        }
    }
}

/// The numbers a tool can be given, named once so the strip and the style
/// cannot disagree about which slider is which.
enum StyleField: String {
    case width, fontSize, blockSize, opacity, tagScale

    /// What the slider may be dragged between, for this tool.
    ///
    /// The same field is not the same size for every tool: a stroke is a few
    /// pixels, and a numbered disc is a label on a screenshot and wants to be
    /// much bigger than 40. One range for both would have made the disc's
    /// maximum the pen's maximum.
    func range(for tool: EditorTool) -> ClosedRange<Double> {
        switch self {
        case .width: tool == .number ? 16...160 : 1...40
        case .fontSize: 8...100
        case .blockSize: 2...48
        case .opacity: 0.1...1
        case .tagScale: 0.5...2.5
        }
    }

    var name: String {
        switch self {
        case .width: L("Width")
        case .fontSize: L("Font Size")
        case .blockSize: L("Block")
        case .opacity: L("Opacity")
        case .tagScale: L("Size")
        }
    }

    /// The caption beside the slider: the number the slider is at, in the unit
    /// that number is in. A percentage where it is a fraction, whole pixels
    /// where it is a length, and a multiplier where the number is a ratio.
    ///
    /// `name` is passed in because the same field is not the same word for
    /// every tool: 30 is a pen's thickness and a numbered disc's diameter.
    func caption(_ value: CGFloat, name: String? = nil) -> String {
        let label = name ?? self.name
        return switch self {
        case .opacity: "\(label) \(Int((value * 100).rounded()))%"
        case .tagScale: "\(label) \(String(format: "%.1f", Double(value)))×"
        default: "\(label) \(Int(value.rounded()))"
        }
    }
}

extension EditorTool {
    /// What a tool is set to before the user has said otherwise.
    ///
    /// These numbers are the thing that makes a highlighter feel like a
    /// highlighter and a mosaic brush like a redaction: pick the tool up and it
    /// is already wide, yellow and see-through, rather than a pen with a
    /// grander name.
    var defaultStyle: ToolStyle {
        var style = ToolStyle()
        switch self {
        case .eyedropper:
            // The picker's `width` is the tag's size multiplier, not a stroke.
            // 1.0 means "the size the picture asked for"; the slider moves it
            // either way from there.
            style.width = 1
        case .select, .hand, .crop, .rectangle, .ellipse, .arrow:
            style.width = 6
        case .pen:
            style.width = 6
        case .highlight:
            style.color = .systemYellow
            style.width = 18
            style.opacity = 0.38
        case .mosaic:
            style.width = 26
            style.blockSize = 16
        case .number:
            // The disc's diameter, drawn from the same slider as a line's width.
            // Sized to be read at a glance on a screenshot that is itself being
            // looked at from across a desk, not at 30 pixels.
            style.width = 48
        case .text:
            // Points are picture pixels here, and a screenshot is a big piece of
            // paper: 16 was caption-sized on anything photographed at Retina
            // resolution, and 32 still read as a caption on a 1600-pixel-wide
            // shot. 40 is the size a label is when it is meant to be read.
            style.fontSize = 40
        }
        return style
    }

    /// Whether the tool paints a colour of its own. A mosaic shows the picture
    /// squared off, and a cursor paints nothing at all — offering either a
    /// colour well is offering a control that does nothing.
    var supportsColour: Bool {
        switch self {
        case .rectangle, .ellipse, .arrow, .pen, .highlight, .text, .number: true
        case .select, .hand, .mosaic, .crop, .eyedropper: false
        }
    }
}

/// The ratios a crop frame can be locked to.
///
/// A list rather than a free-form field: the point of locking is to hit a shape
/// someone else will recognise, and a spinner that takes 1.7778 is not how
/// anyone asks for 16:9.
///
/// Ordered the way the shapes are usually thought about — the square, then the
/// landscape frames getting wider, then the portrait ones getting taller — so
/// the menu can be scanned rather than read. The last two are there because
/// they are somebody's actual job: 4:5 is Instagram's feed, 9:16 is every
/// vertical video's cover, and 2.35:1 is the 900 × 383 公众号 header. A crop
/// lock that only knows 16:9 is a lock that does not save the trip to a
/// calculator.
enum CropAspect: String, CaseIterable {
    case free, square, fourThree, threeTwo, sixteenNine
    case threeFour, fourFive, nineSixteen
    case wechatCover

    var title: String {
        switch self {
        case .free: L("Free")
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .threeFour: "3:4"
        case .fourFive: "4:5"
        case .nineSixteen: "9:16"
        case .wechatCover: "2.35:1"
        }
    }

    /// Width divided by height, or nil when the frame is free.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .threeTwo: 3.0 / 2.0
        case .sixteenNine: 16.0 / 9.0
        case .threeFour: 3.0 / 4.0
        case .fourFive: 4.0 / 5.0
        case .nineSixteen: 9.0 / 16.0
        case .wechatCover: 900.0 / 383.0
        }
    }
}

/// The numbers each tool was last left at, kept for the next launch.
///
/// The editor's defaults are a starting point, not a preference: whoever keeps
/// writing 6-pixel arrows will write 6-pixel arrows every time the window
/// opens, and a default that has to be corrected on every use is a default that
/// is wrong for that person. What is remembered is what the user *changed*, so
/// the numbers below are only ever the value before anyone touched anything.
///
/// Kept in `UserDefaults` rather than in the app's own store: this is a
/// preference about the tool, not a fact about the pictures, and it has no
/// business travelling with a picture file.
enum EditorStyleStore {
    /// Not private: the drill that watches a slider put its number on disk has
    /// to be able to look at the same key, and a copy of the string in the test
    /// is a test that goes quiet when the name changes.
    static let defaultsKey = "editorToolStyles"

    private struct Stored: Codable {
        var width: Double
        var fontSize: Double
        var blockSize: Double
        var opacity: Double
        var isFilled: Bool
        var isBold: Bool
        var isItalic: Bool
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    static func load() -> [EditorTool: ToolStyle] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let raw = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return [:] }
        var styles: [EditorTool: ToolStyle] = [:]
        for (name, stored) in raw {
            guard let tool = EditorTool(rawValue: name) else { continue }
            // The picker's size is never written now; ignore a key left by a
            // build that did, so an old preference cannot open I at 2.5x.
            if tool == .eyedropper { continue }
            var style = tool.defaultStyle
            style.width = CGFloat(stored.width)
            style.fontSize = CGFloat(stored.fontSize)
            style.blockSize = CGFloat(stored.blockSize)
            style.opacity = CGFloat(stored.opacity)
            style.isFilled = stored.isFilled
            style.isBold = stored.isBold
            style.isItalic = stored.isItalic
            style.color = NSColor(srgbRed: stored.red, green: stored.green,
                                  blue: stored.blue, alpha: stored.alpha)
            styles[tool] = style
        }
        return styles
    }

    static func save(_ styles: [EditorTool: ToolStyle]) {
        var raw: [String: Stored] = [:]
        for (tool, style) in styles {
            // A colour tag's size is a setting for one visit to the picker,
            // not a preference. Leaving the key out of the file is what makes
            // "every press of I starts at 1.0x" true across launches too.
            if tool == .eyedropper { continue }
            // A colour that came from the well can be in any space; the one
            // thing worth keeping is what it looks like.
            let srgb = style.color.usingColorSpace(.sRGB) ?? .systemRed
            raw[tool.rawValue] = Stored(
                width: style.width, fontSize: style.fontSize,
                blockSize: style.blockSize, opacity: style.opacity,
                isFilled: style.isFilled, isBold: style.isBold, isItalic: style.isItalic,
                red: srgb.redComponent, green: srgb.greenComponent,
                blue: srgb.blueComponent, alpha: srgb.alphaComponent)
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
