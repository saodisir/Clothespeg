// Eight ways to draw a clothes peg, side by side, so the one that actually
// reads can be picked by looking rather than by guessing.
//
// Usage: swift scripts/peg-lab.swift out.png
//
// The peg has been the sticking point through four rounds. Face on, two short
// ears over a block read as scissors; side on, two arms over a narrow jaw read
// as a slingshot. This sheet tries the space between those two failures.

import AppKit

let cell: CGFloat = 300
let cols = 4, rows = 2
let pad: CGFloat = 24
let W = pad + CGFloat(cols) * (cell + pad)
let H = pad + CGFloat(rows) * (cell + pad)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let ink = rgb(17, 17, 17)
let ground = rgb(236, 236, 236)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
rgb(28, 28, 30).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

func cellBox(_ i: Int) -> NSRect {
    let c = i % cols, r = i / cols
    return NSRect(x: pad + CGFloat(c) * (cell + pad),
                  y: H - pad - CGFloat(r + 1) * (cell + pad) + pad,
                  width: cell, height: cell)
}

// MARK: - the eight drawings

/// 1. Face on, ears flung wide (the current version).
func pegWideEars(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let thick = w * 0.21
    let blockW = w * 0.44
    let blockH = h * 0.46
    let blockBottom = b.minY + h * 0.03
    let blockTop = blockBottom + blockH
    let block = NSBezierPath(
        roundedRect: NSRect(x: cx - blockW/2, y: blockBottom,
                            width: blockW, height: blockH + thick*0.3),
        xRadius: blockW * 0.22, yRadius: blockW * 0.22)
    ink.setFill(); block.fill()
    let tipX = w * 0.5 - thick * 0.5
    let rootX = blockW * 0.5 - thick * 0.30
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s*rootX, y: blockTop - thick*0.1))
        p.line(to: NSPoint(x: cx + s*tipX, y: b.minY + h*0.88))
        p.lineWidth = thick; p.lineCapStyle = .round
        ink.setStroke(); p.stroke()
    }
}

/// 2. Face on, ears nearly parallel — the way a real peg's arms sit.
func pegParallelEars(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let thick = w * 0.20
    let blockW = w * 0.50
    let blockH = h * 0.44
    let blockBottom = b.minY + h * 0.03
    let blockTop = blockBottom + blockH
    let block = NSBezierPath(
        roundedRect: NSRect(x: cx - blockW/2, y: blockBottom,
                            width: blockW, height: blockH + thick*0.3),
        xRadius: blockW * 0.18, yRadius: blockW * 0.18)
    ink.setFill(); block.fill()
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s*blockW*0.26, y: blockTop - thick*0.1))
        p.line(to: NSPoint(x: cx + s*blockW*0.34, y: b.minY + h*0.90))
        p.lineWidth = thick; p.lineCapStyle = .round
        ink.setStroke(); p.stroke()
    }
}

/// 3. Side on, funnel: wide pinched top, solid parallel jaw below.
func pegFunnel(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let thick = w * 0.17
    let mid = b.minY + h * 0.42
    let spread = w * 0.5 - thick * 0.5
    // solid jaw: two arms closed into one mass
    let jawW = thick * 2.1
    let jaw = NSBezierPath(
        roundedRect: NSRect(x: cx - jawW/2, y: b.minY,
                            width: jawW, height: mid - b.minY + thick*0.5),
        xRadius: jawW * 0.30, yRadius: jawW * 0.30)
    ink.setFill(); jaw.fill()
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s*thick*0.55, y: mid))
        p.line(to: NSPoint(x: cx + s*spread, y: b.minY + h*0.92))
        p.lineWidth = thick; p.lineCapStyle = .round
        ink.setStroke(); p.stroke()
    }
}

/// 4. Silhouette: one solid double lobe, split by a single slit.
func pegSilhouette(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let bodyW = w * 0.62
    let body = NSBezierPath(
        roundedRect: NSRect(x: cx - bodyW/2, y: b.minY,
                            width: bodyW, height: h * 0.72),
        xRadius: bodyW * 0.34, yRadius: bodyW * 0.34)
    ink.setFill(); body.fill()
    // slit down the middle of the upper half
    let slitW = w * 0.055
    let slit = NSBezierPath(
        roundedRect: NSRect(x: cx - slitW/2, y: b.minY + h*0.40,
                            width: slitW, height: h*0.34),
        xRadius: slitW*0.5, yRadius: slitW*0.5)
    ground.setFill(); slit.fill()
    // jaw block under it
    let jawW = w * 0.44
    let jaw = NSBezierPath(
        roundedRect: NSRect(x: cx - jawW/2, y: b.minY,
                            width: jawW, height: h * 0.30),
        xRadius: jawW * 0.16, yRadius: jawW * 0.16)
    ink.setFill(); jaw.fill()
}

/// 5. A横向 clip: one bar with two studs. Reads as "clamped", not as a peg.
func clipBar(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let barW = w * 0.86, barH = h * 0.20
    let bar = NSBezierPath(
        roundedRect: NSRect(x: cx - barW/2, y: b.midY - barH/2,
                            width: barW, height: barH),
        xRadius: barH*0.30, yRadius: barH*0.30)
    ink.setFill(); bar.fill()
    for s in [CGFloat(-1), 1] {
        let stud = NSBezierPath(
            roundedRect: NSRect(x: cx + s*barW*0.34 - w*0.055,
                                y: b.midY + barH*0.2,
                                width: w*0.11, height: h*0.30),
            xRadius: w*0.05, yRadius: w*0.05)
        ink.setFill(); stud.fill()
    }
}

/// 6. Face on with a bitten notch: the block's top edge dips between the ears.
func pegNotch(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let thick = w * 0.20
    let blockW = w * 0.52
    let blockH = h * 0.40
    let bottom = b.minY + h * 0.03
    let top = bottom + blockH
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx - blockW/2, y: bottom))
    p.line(to: NSPoint(x: cx - blockW/2, y: top))
    p.line(to: NSPoint(x: cx - blockW*0.10, y: top))
    p.line(to: NSPoint(x: cx, y: top - h*0.10))
    p.line(to: NSPoint(x: cx + blockW*0.10, y: top))
    p.line(to: NSPoint(x: cx + blockW/2, y: top))
    p.line(to: NSPoint(x: cx + blockW/2, y: bottom))
    p.close()
    ink.setFill(); p.fill()
    for s in [CGFloat(-1), 1] {
        let e = NSBezierPath()
        e.move(to: NSPoint(x: cx + s*blockW*0.30, y: top - thick*0.3))
        e.line(to: NSPoint(x: cx + s*blockW*0.42, y: b.minY + h*0.88))
        e.lineWidth = thick; e.lineCapStyle = .round
        ink.setStroke(); e.stroke()
    }
}

/// 7. Three bands: two ears, a gap for the spring, a jaw block.
func pegBanded(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let earW = w * 0.19
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s*w*0.17, y: b.minY + h*0.36))
        p.line(to: NSPoint(x: cx + s*w*0.30, y: b.minY + h*0.92))
        p.lineWidth = earW; p.lineCapStyle = .round
        ink.setStroke(); p.stroke()
    }
    let jawW = w * 0.54
    let jaw = NSBezierPath(
        roundedRect: NSRect(x: cx - jawW/2, y: b.minY,
                            width: jawW, height: h*0.36),
        xRadius: jawW*0.18, yRadius: jawW*0.18)
    ink.setFill(); jaw.fill()
}

/// 8. Close up: only the jaw end, cropped, with the arms leaving the frame.
func pegCrop(_ b: CGRect) {
    let w = b.width, h = b.height, cx = b.midX
    let jawW = w * 0.56
    let jaw = NSBezierPath(
        roundedRect: NSRect(x: cx - jawW/2, y: b.minY,
                            width: jawW, height: h*0.52),
        xRadius: jawW*0.16, yRadius: jawW*0.16)
    ink.setFill(); jaw.fill()
    let earW = w * 0.20
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s*jawW*0.28, y: b.minY + h*0.44))
        p.line(to: NSPoint(x: cx + s*w*0.46, y: b.minY + h*1.05))
        p.lineWidth = earW; p.lineCapStyle = .round
        ink.setStroke(); p.stroke()
    }
}

let drawers: [(String, (CGRect) -> Void)] = [
    ("1 wide ears",  pegWideEars),
    ("2 parallel",   pegParallelEars),
    ("3 funnel",     pegFunnel),
    ("4 silhouette", pegSilhouette),
    ("5 clip bar",   clipBar),
    ("6 notch",      pegNotch),
    ("7 banded",     pegBanded),
    ("8 crop",       pegCrop),
]

for (i, item) in drawers.enumerated() {
    let box = cellBox(i)
    // cell ground
    let rounded = NSBezierPath(roundedRect: box, xRadius: 44, yRadius: 44)
    ground.setFill(); rounded.fill()
    // drawing area inside the cell
    let inner = box.insetBy(dx: cell*0.22, dy: cell*0.14)
    NSGraphicsContext.saveGraphicsState()
    rounded.addClip()
    item.1(inner)
    NSGraphicsContext.restoreGraphicsState()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium),
        .foregroundColor: rgb(150, 150, 155),
    ]
    let s = NSAttributedString(string: item.0, attributes: attrs)
    let sz = s.size()
    s.draw(at: NSPoint(x: box.midX - sz.width/2, y: box.minY + 12))
}

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/peg-lab.png"
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
