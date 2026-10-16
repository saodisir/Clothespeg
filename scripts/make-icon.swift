// Draws the Clothespeg app icon: a wooden peg holding a card.
//
// Usage: swift scripts/make-icon.swift out.png
//
// Drawn by script rather than stored as artwork, for two reasons. A script is
// a drawing that can be changed — a hue is a number in it and a proportion is
// a fraction — so the icon can be tuned without anything being redrawn by eye.
// And it is a resolution, not a picture, so the same drawing is the
// sixteen-point icon in a menu and the thousand-point one in the Dock, which
// is the whole of what an app icon has to be: a shape that still reads at
// sixteen points.
//
// This replaces an earlier script that drew the upstream Tendedero mark. The
// licence that covers this code does not extend to that name or that icon, and
// requires a redistributed version to carry neither; see LICENSE.

import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

/// macOS 图标底板：824/1024 主体，圆角 185/824，带阴影与顶部高光。
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
    // 顶部内高光
    NSGradient(starting: NSColor.white.withAlphaComponent(0.20),
               ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
              angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// 一个木夹子（侧面）：上臂分开是捏手，中间是弹簧，下臂并拢是夹口。
///
/// 关键是上下不对称：只看会画成一个叉。捏手要张开，夹口要合上，
/// 中间一个轴——这三样齐了它才是一根夹子而不是一个蝴蝶结。
func clothespin(_ box: CGRect, wood: NSColor, metal: NSColor) {
    let side = min(box.width, box.height)
    let cx = box.midX
    let top = box.midY + side * 0.40
    let mid = box.midY + side * 0.01
    let bottom = box.midY - side * 0.42

    let spread = side * 0.185       // 捏手张开半宽
    let jaw = side * 0.052          // 夹口半宽（几乎并拢）
    let thick = side * 0.115        // 木条粗细

    // 上臂：两条从外到内收拢
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s * spread, y: top))
        p.line(to: NSPoint(x: cx + s * jaw, y: mid))
        p.lineWidth = thick
        p.lineCapStyle = .round
        wood.setStroke()
        p.stroke()
    }
    // 下臂：两条贴在一起（夹口闭合），略细一点，看起来像咬合
    for s in [CGFloat(-1), 1] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + s * jaw * 0.85, y: mid))
        p.line(to: NSPoint(x: cx + s * jaw * 0.55, y: bottom))
        p.lineWidth = thick * 0.92
        p.lineCapStyle = .round
        wood.blended(withFraction: 0.10, of: .black)?.setStroke()
        p.stroke()
    }

    // 弹簧轴：盖在交叉处
    let r = side * 0.085
    let coil = NSRect(x: cx - r, y: mid - r, width: r * 2, height: r * 2)
    let cp = NSBezierPath(ovalIn: coil)
    NSGraphicsContext.saveGraphicsState()
    cp.addClip()
    NSGradient(starting: .white, ending: metal)!.draw(in: coil, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    (metal.blended(withFraction: 0.45, of: .black) ?? metal).setStroke()
    cp.lineWidth = side * 0.015
    cp.stroke()
}

/// 晾衣绳：一根下垂的弧线。
func line(_ box: CGRect, color: NSColor, sag: CGFloat = 0.16) {
    let y = box.midY + box.height * 0.16
    let path = NSBezierPath()
    path.move(to: NSPoint(x: box.minX, y: y))
    path.curve(to: NSPoint(x: box.maxX, y: y),
               controlPoint1: NSPoint(x: box.minX + box.width * 0.32, y: y - box.height * sag),
               controlPoint2: NSPoint(x: box.maxX - box.width * 0.32, y: y - box.height * sag))
    color.setStroke()
    path.lineWidth = box.width * 0.035
    path.lineCapStyle = .round
    path.stroke()
}

/// 一张抽象卡片：一个圆角矩形 + 两行"字"。
func card(_ box: CGRect, ink: NSColor, ground: NSColor, alpha: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: box, xRadius: box.width * 0.14,
                            yRadius: box.width * 0.14)
    ground.withAlphaComponent(alpha).setFill()
    path.fill()
    ink.withAlphaComponent(0.26 * alpha).setFill()
    let lh = box.height * 0.075
    for (i, w) in [0.66, 0.44, 0.55].enumerated() {
        NSRect(x: box.minX + box.width * 0.16,
               y: box.maxY - box.height * (0.26 + CGFloat(i) * 0.20),
               width: box.width * w, height: lh).fill()
    }
}


let slate = rgb(120, 130, 148), slateDeep = rgb(74, 84, 102)
let amberDeep = rgb(198, 118, 34)

// A wooden clothespin holding a card: the defining mark of an app whose whole
// job is to hold the last thing you copied.
let box = NSRect(x: 0, y: 0, width: size, height: size)
plate(box, slate, slateDeep)
let inner = box.insetBy(dx: box.width * 0.21, dy: box.width * 0.21)
let cw = inner.width * 0.56, ch = inner.height * 0.54
card(NSRect(x: inner.midX - cw / 2, y: inner.midY - ch * 0.62,
            width: cw, height: ch),
     ink: slateDeep, ground: rgb(250, 251, 253))
let sw = inner.width * 0.30
clothespin(NSRect(x: inner.midX - sw / 2, y: inner.midY - inner.height * 0.14,
                  width: sw, height: sw * 2.1),
           wood: rgb(255, 240, 214), metal: amberDeep)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
