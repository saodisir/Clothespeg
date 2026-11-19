import AppKit

// Whole chips, not bare symbols: the question this answers is what a *pair* of
// symbols looks like inside the bar's 46-point chipped menu — symbol in the 30
// points a chip has, a 6.5-point key in the corner, a chevron in the 16 beside
// it. A symbol can read fine on its own and still be wrong here.
//
// Run: swift scripts/symbol-pairs.swift /tmp/pairs.png

/// Candidate pairs: `(side by side, in place)`.
let pairs: [(String, String)] = [
    ("translate", "rectangle.on.rectangle"),
    ("rectangle.split.2x1", "rectangle.on.rectangle"),
    ("rectangle.split.2x1", "rectangle.portrait.on.rectangle.portrait"),
    ("text.bubble", "rectangle.on.rectangle.slash"),
    ("doc.on.doc", "rectangle.on.rectangle"),
    ("rectangle.split.2x1", "rectangle.on.rectangle.angled"),
]

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/pairs.png"

let chipSize = NSSize(width: 46, height: 26)
/// The 16 points at the right end that open the menu.
let menuWidth: CGFloat = 16
let rowHeight: CGFloat = 46
let margin: CGFloat = 10
let size = NSSize(width: 520,
                  height: margin * 2 + rowHeight * CGFloat(pairs.count))

let image = NSImage(size: size)
image.lockFocus()
NSColor(srgbRed: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf3 / 255, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let ink = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 0.92)
var missing: [String] = []

func drawChip(_ origin: NSPoint, symbol: String) {
    let chip = NSRect(x: origin.x, y: origin.y, width: chipSize.width, height: chipSize.height)
    ink.withAlphaComponent(0.10).setFill()
    NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()

    let body = NSRect(x: chip.minX, y: chip.minY,
                      width: chip.width - menuWidth, height: chip.height)
    if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        let glyph = base.withSymbolConfiguration(config) ?? base
        glyph.draw(in: NSRect(x: body.midX - glyph.size.width / 2,
                              y: chip.midY - glyph.size.height / 2,
                              width: glyph.size.width, height: glyph.size.height))
    } else {
        missing.append(symbol)
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.5
        cross.move(to: NSPoint(x: body.minX + 6, y: chip.minY + 6))
        cross.line(to: NSPoint(x: body.maxX - 6, y: chip.maxY - 6))
        cross.move(to: NSPoint(x: body.maxX - 6, y: chip.minY + 6))
        cross.line(to: NSPoint(x: body.minX + 6, y: chip.maxY - 6))
        cross.stroke()
    }

    let badge = NSAttributedString(string: "M", attributes: [
        .font: NSFont.systemFont(ofSize: 6.5, weight: .semibold),
        .foregroundColor: ink.withAlphaComponent(0.5),
    ])
    badge.draw(at: NSPoint(x: body.maxX - badge.size().width - 3, y: chip.minY + 2))

    // The chevron, drawn the way `drawChevron` draws it.
    let centre = NSPoint(x: chip.maxX - menuWidth / 2, y: chip.midY + 1.5)
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: centre.x - 3.5, y: centre.y + 2))
    chevron.line(to: NSPoint(x: centre.x, y: centre.y - 1.5))
    chevron.line(to: NSPoint(x: centre.x + 3.5, y: centre.y + 2))
    chevron.lineWidth = 1.4
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    ink.setStroke()
    chevron.stroke()
}

for (index, pair) in pairs.enumerated() {
    let y = size.height - margin - CGFloat(index + 1) * rowHeight
    drawChip(NSPoint(x: margin, y: y + 10), symbol: pair.0)
    drawChip(NSPoint(x: margin + chipSize.width + 8, y: y + 10), symbol: pair.1)
    let label = NSAttributedString(string: "\(pair.0)  ·  \(pair.1)", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1),
    ])
    label.draw(at: NSPoint(x: margin + 2 * chipSize.width + 28, y: y + 18))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("pairs: could not encode")
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
let unique = Set(pairs.flatMap { [$0.0, $0.1] })
print("pairs: \(pairs.count) rows, \(unique.count - Set(missing).count)/\(unique.count) symbols present → \(out)")
if !missing.isEmpty { print("missing: " + Set(missing).sorted().joined(separator: ", ")) }
