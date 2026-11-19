import AppKit

// A sheet of candidate symbols for the capture bar, drawn the way the bar draws
// them: 14 pt on a 30 × 26 chip's 10-11% ink, with a key badge in the corner.
//
// Run: swift scripts/symbol-sheet.swift /tmp/symbols.png
// The question it answers is not "does this symbol exist" — the self-test says
// that — but "does it still read at the size it is drawn, with a 6.5-point `M`
// over its bottom-right corner".

let names = [
    "captions.bubble",
    "text.above.photo",
    "photo.on.rectangle",
    "bubble.left.and.bubble.right",
    "character.text.justify",
    "text.append",
    "text.rectangle",
    "text.line.first.and.arrowtriangle.forward",
    "character.square.on.square",
    "square.and.text.bubble",
    "text.bubble.fill",
    "character.bubble.fill",
    "character.textbox",
    "translate",
    "text.insert",
    "text.alignleft",
]

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/symbols.png"

let tile = NSSize(width: 132, height: 74)
let columns = 4
let rows = (names.count + columns - 1) / columns
let size = NSSize(width: tile.width * CGFloat(columns), height: tile.height * CGFloat(rows))

let image = NSImage(size: size)
image.lockFocus()
NSColor(srgbRed: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf3 / 255, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let ink = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 0.92)
var missing: [String] = []

for (index, name) in names.enumerated() {
    let column = index % columns
    let row = index / columns
    let origin = NSPoint(x: CGFloat(column) * tile.width,
                         y: size.height - CGFloat(row + 1) * tile.height)

    // The chip, exactly as the bar draws a 30 × 26 one.
    let chip = NSRect(x: origin.x + 8, y: origin.y + 26, width: 30, height: 26)
    ink.withAlphaComponent(0.10).setFill()
    NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()

    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        missing.append(name)
        // A visible cross, so a missing symbol is a red mark on the sheet rather
        // than a blank tile somebody reads as "the icon is empty".
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.5
        cross.move(to: NSPoint(x: chip.minX + 8, y: chip.minY + 7))
        cross.line(to: NSPoint(x: chip.maxX - 8, y: chip.maxY - 7))
        cross.move(to: NSPoint(x: chip.maxX - 8, y: chip.minY + 7))
        cross.line(to: NSPoint(x: chip.minX + 8, y: chip.maxY - 7))
        cross.stroke()
        continue
    }
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
    let glyph = base.withSymbolConfiguration(config) ?? base
    glyph.draw(in: NSRect(x: chip.midX - glyph.size.width / 2,
                          y: chip.midY - glyph.size.height / 2,
                          width: glyph.size.width, height: glyph.size.height))

    // The key in the corner, the way `drawHint` puts it there: 6.5 pt, 3 from
    // the right edge and 2 from the bottom.
    let badge = NSAttributedString(string: "M", attributes: [
        .font: NSFont.systemFont(ofSize: 6.5, weight: .semibold),
        .foregroundColor: ink.withAlphaComponent(0.5),
    ])
    badge.draw(at: NSPoint(x: chip.maxX - badge.size().width - 3, y: chip.minY + 2))

    // And the names, under the chip, at the size a person reads a label.
    let label = NSAttributedString(string: name, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1),
    ])
    label.draw(at: NSPoint(x: origin.x + 6, y: origin.y + 8))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("sheet: could not encode")
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: out))
} catch {
    print("sheet: \(error)")
    exit(1)
}
print("sheet: \(names.count - missing.count)/\(names.count) present → \(out)")
if !missing.isEmpty { print("missing: " + missing.joined(separator: ", ")) }
