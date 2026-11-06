// Three Clothespeg icon candidates, drawn from one parameterised recogniser.
//
// Usage: swift scripts/icon-candidates.swift <outdir>
//
// Why a script and not artwork: a hue here is a number and a proportion is a
// fraction, so the mark can be tuned without anything being redrawn by eye,
// and the same drawing is the sixteen-point icon and the thousand-point one.
//
// The shape is the one that survived the shelf test — a peg biting the top
// edge of a card, with no rope and no ruled lines. The rope was three pixels
// wide at Dock size, which is dirt rather than information. The ruled lines
// said "document", which is what Notes, TextEdit and Reminders already say.

import AppKit

let size: CGFloat = 1024
let outDir = CommandLine.arguments.dropFirst().first ?? "build/icon-v2"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

// Straps taken from CDSTokens: the terracotta is the only accent the app has,
// so it is the only saturated thing on the plate.
let clay = rgb(217, 119, 87)
let cream = rgb(248, 247, 244)
let charcoal = rgb(21, 21, 21)

struct Recipe {
    let name: String
    let plateTop: NSColor
    let plateBottom: NSColor
    let card: NSColor
    let cardShadow: CGFloat
    let peg: NSColor
    let spring: NSColor
    let footBand: NSColor?
    let tilt: CGFloat        // degrees, clockwise about the icon centre
}

/// macOS icon plate: 824/1024 body, corner 185/824, with shadow and top sheen.
func plate(_ rect: CGRect, _ top: NSColor, _ bottom: NSColor) {
    let side = rect.width
    let body = rect.insetBy(dx: side * 0.098, dy: side * 0.098)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2245,
                            yRadius: body.width * 0.2245)

    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.34)
    s.shadowBlurRadius = side * 0.026
    s.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    s.set()
    rgb(60, 64, 78).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: bottom, ending: top)!.draw(in: body, angle: -90)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.14),
               ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: body.minX, y: body.midY,
                         width: body.width, height: body.height / 2),
              angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// A card: rounded rectangle, optional band across the foot.
func card(_ rect: CGRect, fill: NSColor, band: NSColor?, shadow: CGFloat) {
    let radius = rect.width * 0.115
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(shadow)
    s.shadowBlurRadius = rect.width * 0.045
    s.shadowOffset = NSSize(width: 0, height: -rect.width * 0.014)
    s.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let band else { return }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    band.setFill()
    NSRect(x: rect.minX, y: rect.minY,
           width: rect.width, height: rect.height * 0.105).fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// A peg, face on. Three lumps of information, in this order of importance:
/// a jaw block that bites the card, two pinched ears above it, and the spring
/// where the arms meet. Side on, only one arm is visible and the shape reads
/// as a slingshot at Dock size; face on, the three lumps survive reduction.
///
///   block  bottom, the jaw, sits over the card's top edge
///   ears   two thick stubs flaring up and out, ~22 degrees off vertical
///   spring one dot, the thing that stops it reading as a pair of ears
func peg(_ rect: CGRect, wood: NSColor, spring: NSColor) {
    let w = rect.width, h = rect.height
    let cx = rect.midX

    let thick = w * 0.21
    let blockW = w * 0.44          // narrow: a wide block flattens the ear angle
    let blockH = h * 0.46
    let blockBottom = rect.minY + h * 0.03
    let blockTop = blockBottom + blockH

    // The peg is a thing lying on top of the card, so it has to throw a
    // shadow onto it. Without one it reads as pushed into the card, not
    // gripping it, and the whole mark goes flat.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.42)
    sh.shadowBlurRadius = w * 0.13
    sh.shadowOffset = NSSize(width: 0, height: -w * 0.045)
    sh.set()

    // Jaw block. Taller than it is wide, so it carries the weight at the
    // bottom instead of reading as a bag the ears are stuck into.
    let block = NSBezierPath(
        roundedRect: NSRect(x: cx - blockW / 2, y: blockBottom,
                            width: blockW, height: blockH + thick * 0.30),
        xRadius: blockW * 0.22, yRadius: blockW * 0.22)
    wood.setFill()
    block.fill()

    // Ears. Short and thick on purpose: a long thin arm reads as a chopstick
    // and the pair of them reads as a slingshot. Rooted inside the block's
    // shoulders so the silhouette stays one object.
    let tipX = w * 0.5 - thick * 0.5
    let rootX = blockW * 0.5 - thick * 0.30
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s * rootX, y: blockTop - thick * 0.10))
        p.line(to: NSPoint(x: cx + s * tipX, y: rect.minY + h * 0.88))
        p.lineWidth = thick
        p.lineCapStyle = .round
        wood.setStroke()
        p.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Spring, bedded into the top of the block: the one dot that separates
    // a peg from a pair of rabbit ears.
    let sr = w * 0.10
    let coil = NSRect(x: cx - sr, y: blockTop - sr * 0.45,
                      width: sr * 2, height: sr * 2)
    let cp = NSBezierPath(ovalIn: coil)
    NSGraphicsContext.saveGraphicsState()
    cp.addClip()
    NSGradient(starting: .white, ending: spring)!.draw(in: coil, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    spring.setStroke()
    cp.lineWidth = w * 0.012
    cp.stroke()
}

func render(_ r: Recipe, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let box = NSRect(x: 0, y: 0, width: size, height: size)
    plate(box, r.plateTop, r.plateBottom)
    let body = box.insetBy(dx: size * 0.098, dy: size * 0.098)

    // Card and peg turn together, about the icon centre.
    NSGraphicsContext.saveGraphicsState()
    if r.tilt != 0 {
        let t = NSAffineTransform()
        t.translateX(by: body.midX, yBy: body.midY)
        t.rotate(byDegrees: r.tilt)
        t.translateX(by: -body.midX, yBy: -body.midY)
        t.concat()
    }

    // Taller than wide: a square card reads as a signboard, a 4:5 card reads
    // as a note.
    let cw = body.width * 0.42
    let ch = body.height * 0.52
    let cardRect = NSRect(x: body.midX - cw / 2,
                          y: body.minY + body.height * 0.10,
                          width: cw, height: ch)
    card(cardRect, fill: r.card, band: r.footBand, shadow: r.cardShadow)

    let pw = cw * 0.42
    let ph = pw * 1.45
    let pegRect = NSRect(x: body.midX - pw / 2,
                         y: cardRect.maxY - ph * 0.18,
                         width: pw, height: ph)
    peg(pegRect, wood: r.peg, spring: r.spring)

    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let recipes: [Recipe] = [
    // V1 — charcoal. The only dark plate in a Dock of pale system icons.
    Recipe(name: "V1-charcoal",
           plateTop: rgb(30, 30, 34), plateBottom: rgb(12, 12, 14),
           card: cream, cardShadow: 0.45,
           peg: clay, spring: rgb(252, 251, 248),
           footBand: nil, tilt: 0),

    // V2 — warm ground with a foot band. Safest, but sits near Notes.
    Recipe(name: "V2-warm",
           plateTop: rgb(251, 251, 249), plateBottom: rgb(235, 235, 231),
           card: rgb(255, 255, 255), cardShadow: 0.18,
           peg: clay, spring: rgb(252, 251, 248),
           footBand: clay, tilt: 0),

    // V3 — clay ground, tilted. Breaks the mirror symmetry that made the
    // upright versions read as a signboard with something growing out of it.
    Recipe(name: "V3-clay",
           plateTop: rgb(226, 141, 108), plateBottom: rgb(196, 100, 70),
           card: cream, cardShadow: 0.35,
           peg: charcoal, spring: rgb(252, 251, 248),
           footBand: nil, tilt: -9),
]

for r in recipes {
    render(r, to: "\(outDir)/\(r.name).png")
}
