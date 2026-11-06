// Eight Clothespeg icon directions, in greyscale, drawn from primitives.
//
// Usage: swift scripts/icon-explore.swift <outdir>
//
// Following the discipline the logo-design skill insists on: shape first,
// colour later. A mark that only works because it is terracotta has not been
// designed, it has been painted.
//
// Two families, four each:
//   tag     the mark is a hang tag — rope, peg, and a tag whose outline IS
//           the screenshot frame. Four parts collapsed into one object.
//   finder  the icon itself is the viewfinder — four corner marks at the
//           plate's edge, with the card and peg inside them.

import AppKit

let size: CGFloat = 1024
let outDir = CommandLine.arguments.dropFirst().first ?? "build/icon-v2"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

let paperWhite = rgb(255, 255, 255)
let groundPale = rgb(232, 232, 232)
let ink = rgb(17, 17, 17)

/// macOS plate: 824/1024 body, corner 185/824.
func plate(_ rect: CGRect, _ top: NSColor, _ bottom: NSColor) {
    let side = rect.width
    let body = rect.insetBy(dx: side * 0.098, dy: side * 0.098)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2245,
                            yRadius: body.width * 0.2245)
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.28)
    s.shadowBlurRadius = side * 0.026
    s.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    s.set()
    rgb(60, 64, 78).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: bottom, ending: top)!.draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// Four corner marks — the viewfinder. Each is an L drawn from the corner
/// outwards, round caps, so the eye reads a frame without a frame.
func corners(_ rect: CGRect, arm: CGFloat, thick: CGFloat, color: NSColor) {
    let half = thick / 2
    let r = rect.insetBy(dx: half, dy: half)
    color.setStroke()
    let pts: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: r.minX, y: r.minY), 1, 1),
        (CGPoint(x: r.maxX, y: r.minY), -1, 1),
        (CGPoint(x: r.minX, y: r.maxY), 1, -1),
        (CGPoint(x: r.maxX, y: r.maxY), -1, -1),
    ]
    for (p, sx, sy) in pts {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: p.x + sx * arm, y: p.y))
        path.line(to: p)
        path.line(to: CGPoint(x: p.x, y: p.y + sy * arm))
        path.lineWidth = thick
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

/// A card: rounded rectangle with a soft shadow so it sits above the plate.
func card(_ rect: CGRect, fill: NSColor, shadow: CGFloat, radius: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(shadow)
    s.shadowBlurRadius = rect.width * 0.05
    s.shadowOffset = NSSize(width: 0, height: -rect.width * 0.016)
    s.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// Four arcs hugging the plate's corners — a viewfinder that follows the
/// squircle instead of cutting across it. Square L marks read as crop marks
/// on a print sheet; an arc that echoes the plate's own radius reads as a
/// camera.
func arcCorners(_ rect: CGRect, thick: CGFloat, color: NSColor) {
    let r = rect.width * 0.150
    let pad: CGFloat = 3
    color.setStroke()
    let arcs: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: rect.minX + r, y: rect.minY + r), 180, 270),
        (CGPoint(x: rect.maxX - r, y: rect.minY + r), 270, 360),
        (CGPoint(x: rect.maxX - r, y: rect.maxY - r), 0, 90),
        (CGPoint(x: rect.minX + r, y: rect.maxY - r), 90, 180),
    ]
    for (c, a0, a1) in arcs {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r,
                    startAngle: a0 + pad, endAngle: a1 - pad)
        p.lineWidth = thick
        p.lineCapStyle = .round
        p.stroke()
    }
}

/// A peg, face on. Not the flared V that reads as scissors: two arms that
/// stay close to parallel, a jaw block, and a spring hole. The V was the
/// mistake — a real peg's arms barely diverge, and the flare is what made
/// four earlier rounds look like a slingshot.
func peg(_ rect: CGRect, wood: NSColor, spring: NSColor) {
    let w = rect.width, h = rect.height
    let cx = rect.midX
    let thick = w * 0.20
    let blockW = w * 0.50
    let blockH = h * 0.42
    let blockBottom = rect.minY + h * 0.03
    let blockTop = blockBottom + blockH

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
    sh.shadowBlurRadius = w * 0.10
    sh.shadowOffset = NSSize(width: 0, height: -w * 0.035)
    sh.set()

    let block = NSBezierPath(
        roundedRect: NSRect(x: cx - blockW / 2, y: blockBottom,
                            width: blockW, height: blockH + thick * 0.30),
        xRadius: blockW * 0.18, yRadius: blockW * 0.18)
    wood.setFill()
    block.fill()

    // Arms sit almost straight up, splaying only a few degrees.
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s * blockW * 0.25, y: blockTop - thick * 0.1))
        p.line(to: NSPoint(x: cx + s * blockW * 0.33, y: rect.minY + h * 0.92))
        p.lineWidth = thick
        p.lineCapStyle = .round
        wood.setStroke()
        p.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Spring, knocked out of the block rather than drawn on it: in greyscale
    // a light dot is the only way to say "there is a pivot here".
    let sr = w * 0.135
    let coil = NSBezierPath(ovalIn: NSRect(x: cx - sr, y: blockTop - sr * 0.55,
                                           width: sr * 2, height: sr * 2))
    spring.setFill()
    coil.fill()
}

/// A rope sagging between two points.
func rope(_ a: CGPoint, _ b: CGPoint, sag: CGFloat, thick: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: a)
    path.curve(to: b,
               controlPoint1: CGPoint(x: a.x + (b.x - a.x) * 0.33, y: a.y - sag),
               controlPoint2: CGPoint(x: a.x + (b.x - a.x) * 0.67, y: b.y - sag))
    color.setStroke()
    path.lineWidth = thick
    path.lineCapStyle = .round
    path.stroke()
}

enum Mode { case tag, finder, combo }

struct Spec {
    let name: String
    let mode: Mode
    let tilt: CGFloat
    let cards: Int          // how many cards behind the front one
    let rope: Bool
    let wideTag: Bool
    let frameInset: CGFloat // finder family: corner mark inset, fraction of body
    let frameArm: CGFloat   // finder family: arm length, fraction of body

    // Colour. Defaults keep every greyscale spec as it was.
    var plateTop: NSColor = groundPale
    var plateBottom: NSColor = rgb(214, 214, 214)
    var cardFill: NSColor = paperWhite
    var pegColor: NSColor = ink
    var ropeColor: NSColor = ink
    var frameColor: NSColor = ink
}

func render(_ s: Spec) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let box = NSRect(x: 0, y: 0, width: size, height: size)
    plate(box, s.plateTop, s.plateBottom)
    let body = box.insetBy(dx: size * 0.098, dy: size * 0.098)

    NSGraphicsContext.saveGraphicsState()
    if s.tilt != 0 {
        let t = NSAffineTransform()
        t.translateX(by: body.midX, yBy: body.midY)
        t.rotate(byDegrees: s.tilt)
        t.translateX(by: -body.midX, yBy: -body.midY)
        t.concat()
    }

    switch s.mode {
    case .tag:
        // rope across the top, peg hanging on it, tag hanging from the peg
        let ropeY = body.maxY - body.height * 0.13
        let sag = body.height * 0.075
        if s.rope {
            rope(CGPoint(x: body.minX + body.width * 0.02, y: ropeY),
                 CGPoint(x: body.maxX - body.width * 0.02, y: ropeY),
                 sag: sag, thick: body.width * 0.022, color: s.ropeColor)
        }
        let hangY = ropeY - sag

        let tw = body.width * (s.wideTag ? 0.58 : 0.36)
        let th = body.height * (s.wideTag ? 0.34 : 0.60)

        let pw = tw * (s.wideTag ? 0.16 : 0.34)
        let ph = pw * 1.45
        let pegBottom = hangY - ph * 0.52
        let tagTop = pegBottom + ph * 0.16
        let tagRect = NSRect(x: body.midX - tw / 2, y: tagTop - th,
                             width: tw, height: th)

        // cards behind the tag, offset up-left so they read as a stack
        for i in stride(from: s.cards, through: 1, by: -1) {
            let d = CGFloat(i) * tw * 0.105
            card(tagRect.offsetBy(dx: -d, dy: d * 0.75),
                 fill: paperWhite, shadow: 0.16, radius: tw * 0.10)
        }
        card(tagRect, fill: paperWhite, shadow: 0.24, radius: tw * 0.10)
        corners(tagRect, arm: tw * 0.26, thick: tw * 0.068, color: ink)
        peg(NSRect(x: body.midX - pw / 2, y: pegBottom,
                   width: pw, height: ph), wood: s.pegColor, spring: s.cardFill)

    case .finder:
        let cw = body.width * 0.40
        let ch = body.height * 0.48
        let cardRect = NSRect(x: body.midX - cw / 2,
                              y: body.minY + body.height * 0.16,
                              width: cw, height: ch)

        if s.rope {
            let ropeY = cardRect.maxY + body.height * 0.10
            rope(CGPoint(x: body.minX + body.width * 0.06, y: ropeY),
                 CGPoint(x: body.maxX - body.width * 0.06, y: ropeY),
                 sag: body.height * 0.045, thick: body.width * 0.020, color: s.ropeColor)
        }

        for i in stride(from: s.cards, through: 1, by: -1) {
            let d = CGFloat(i) * cw * 0.105
            card(cardRect.offsetBy(dx: -d, dy: d * 0.8),
                 fill: paperWhite, shadow: 0.16, radius: cw * 0.11)
        }
        card(cardRect, fill: paperWhite, shadow: 0.24, radius: cw * 0.11)

        let pw = cw * 0.42
        let ph = pw * 1.45
        peg(NSRect(x: body.midX - pw / 2, y: cardRect.maxY - ph * 0.18,
                   width: pw, height: ph), wood: s.pegColor, spring: s.cardFill)

        let fw = body.width * (1 - s.frameInset * 2)
        let frect = NSRect(x: body.midX - fw / 2, y: body.midY - fw / 2,
                           width: fw, height: fw)
        corners(frect, arm: body.width * s.frameArm,
                thick: body.width * 0.020, color: ink)

    case .combo:
        // Rope across the top, peg hanging on it, two or three cards
        // hanging from the peg, viewfinder arcing around the plate corners.
        // In this family frameArm is a stroke width, not an arm length.
        let ropeY = body.maxY - body.height * 0.155
        let sag = body.height * 0.070
        if s.rope {
            rope(CGPoint(x: body.minX + body.width * 0.11, y: ropeY),
                 CGPoint(x: body.maxX - body.width * 0.11, y: ropeY),
                 sag: sag, thick: body.width * 0.024, color: s.ropeColor)
        }
        let hangY = ropeY - sag

        let cw = body.width * 0.46
        let ch = body.height * 0.53
        let pw = cw * 0.30
        let ph = pw * 1.45
        let pegBottom = hangY - ph * 0.55
        // The card's top edge sits inside the peg, not below it: a peg that
        // floats above a card is not holding anything.
        let cardTop = pegBottom + ph * 0.02
        let cardRect = NSRect(x: body.midX - cw / 2, y: cardTop - ch,
                              width: cw, height: ch)

        // Back cards alternate sides, which reads as a stack; the same-side
        // offset reads as a printing misregistration.
        for i in stride(from: s.cards, through: 1, by: -1) {
            let d = CGFloat(i) * cw * 0.080
            let sx: CGFloat = (i % 2 == 0) ? -1 : 1
            card(cardRect.offsetBy(dx: sx * d, dy: d * 0.55),
                 fill: s.cardFill, shadow: 0.18, radius: cw * 0.10)
        }
        card(cardRect, fill: s.cardFill, shadow: 0.26, radius: cw * 0.10)
        peg(NSRect(x: body.midX - pw / 2, y: pegBottom,
                   width: pw, height: ph), wood: s.pegColor, spring: s.cardFill)

    }

    // Tilt ends here. The viewfinder is drawn outside it: the frame is the
    // icon's skeleton, only the things hanging inside it may lean.
    NSGraphicsContext.restoreGraphicsState()
    if s.mode == .combo {
        let fw = body.width * (1 - s.frameInset * 2)
        let frect = NSRect(x: body.midX - fw / 2, y: body.midY - fw / 2,
                           width: fw, height: fw)
        arcCorners(frect, thick: body.width * s.frameArm, color: s.frameColor)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(s.name).png"))
    print("wrote \(s.name).png")
}

let specs: [Spec] = [
    // A — hang tag
    Spec(name: "A1-tag-rope", mode: .tag, tilt: 0, cards: 0, rope: true,
         wideTag: false, frameInset: 0, frameArm: 0),
    Spec(name: "A2-tag-tilt", mode: .tag, tilt: -8, cards: 0, rope: true,
         wideTag: false, frameInset: 0, frameArm: 0),
    Spec(name: "A3-tag-stack", mode: .tag, tilt: 0, cards: 2, rope: true,
         wideTag: false, frameInset: 0, frameArm: 0),
    Spec(name: "A4-tag-wide", mode: .tag, tilt: 0, cards: 0, rope: true,
         wideTag: true, frameInset: 0, frameArm: 0),

    // B — the icon is the viewfinder
    Spec(name: "B1-finder-small", mode: .finder, tilt: 0, cards: 0, rope: false,
         wideTag: false, frameInset: 0.10, frameArm: 0.13),
    Spec(name: "B2-finder-large", mode: .finder, tilt: 0, cards: 2, rope: false,
         wideTag: false, frameInset: 0.05, frameArm: 0.19),
    Spec(name: "B3-finder-rope", mode: .finder, tilt: 0, cards: 0, rope: true,
         wideTag: false, frameInset: 0.08, frameArm: 0.15),
    Spec(name: "B4-finder-edge", mode: .finder, tilt: 0, cards: 0, rope: false,
         wideTag: false, frameInset: 0.060, frameArm: 0.20),

    // C — rope + peg + stacked cards + arc viewfinder
    Spec(name: "C1-combo-two", mode: .combo, tilt: 0, cards: 1, rope: true,
         wideTag: false, frameInset: 0.058, frameArm: 0.032),
    Spec(name: "C2-combo-three", mode: .combo, tilt: 0, cards: 2, rope: true,
         wideTag: false, frameInset: 0.058, frameArm: 0.032),
    Spec(name: "C3-combo-tilt", mode: .combo, tilt: -7, cards: 1, rope: true,
         wideTag: false, frameInset: 0.058, frameArm: 0.032),
    Spec(name: "C4-combo-heavy", mode: .combo, tilt: 0, cards: 1, rope: true,
         wideTag: false, frameInset: 0.040, frameArm: 0.042),

    // Colour trials on the best structure so far (rope + peg + two cards +
    // arc viewfinder), so the only variable is the palette.
    Spec(name: "P1-clay-ground", mode: .combo, tilt: 0, cards: 1, rope: true,
         wideTag: false, frameInset: 0.058, frameArm: 0.032,
         plateTop: rgb(226, 141, 108), plateBottom: rgb(198, 101, 70),
         cardFill: rgb(250, 249, 246), pegColor: rgb(26, 26, 28),
         ropeColor: rgb(26, 26, 28), frameColor: rgb(250, 249, 246)),
    Spec(name: "P2-cream-ground", mode: .combo, tilt: 0, cards: 1, rope: true,
         wideTag: false, frameInset: 0.058, frameArm: 0.032,
         plateTop: rgb(252, 252, 250), plateBottom: rgb(232, 232, 228),
         cardFill: rgb(255, 255, 255), pegColor: rgb(217, 119, 87),
         ropeColor: rgb(217, 119, 87), frameColor: rgb(217, 119, 87)),
    Spec(name: "P3-charcoal-ground", mode: .combo, tilt: 0, cards: 1, rope: true,
         wideTag: false, frameInset: 0.058, frameArm: 0.032,
         plateTop: rgb(32, 32, 36), plateBottom: rgb(14, 14, 16),
         cardFill: rgb(248, 247, 244), pegColor: rgb(217, 119, 87),
         ropeColor: rgb(217, 119, 87), frameColor: rgb(217, 119, 87)),
    Spec(name: "P4-cream-orange-frame", mode: .combo, tilt: 0, cards: 1, rope: true,
         wideTag: false, frameInset: 0.058, frameArm: 0.032,
         plateTop: rgb(252, 252, 250), plateBottom: rgb(232, 232, 228),
         cardFill: rgb(255, 255, 255), pegColor: rgb(26, 26, 28),
         ropeColor: rgb(26, 26, 28), frameColor: rgb(217, 119, 87)),
]

for s in specs { render(s) }
