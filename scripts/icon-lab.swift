// Clothespeg 2.0 图标实验台。
//
// 用法：swift scripts/icon-lab.swift <方案名> <输出.png>
//
// 用脚本画而不是存成品图，是为了每个色值、每个比例都是可改的数字。
// 底板尺寸遵循 macOS 图标规范：1024 画布，824 主体，圆角 185。

import AppKit

let S: CGFloat = 1024
let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// MARK: - 颜色

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: a)
}

// CDSTokens 的两个主色
let clay     = hex(0xD97757)   // 陶土橙
let clayDeep = hex(0xB4543A)
let clayLite = hex(0xE9987B)
let groundLt = hex(0xF5F5F3)   // 暖地面 浅
let groundDk = hex(0x151515)   // 暖地面 深
let shadowInk = hex(0x1E1712)  // 阴影不用纯黑：压暖色上会发青；但也别太暖，投在透明底上会泛红边

// MARK: - 底板

/// 底板矩形。绳子要沿着它的圆角裁掉两端，所以得存下来。
var bodyRect = CGRect.zero

func plate(top: NSColor, bottom: NSColor, outerShadow: CGFloat = 0.24, rim: CGFloat = 0.30) {
    let inset = S * 0.098
    let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let r = body.width * 0.2245
    bodyRect = body
    let path = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)

    // 投影：一次带 shadow 的填充，形状与影子一起出来
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = shadowInk.withAlphaComponent(outerShadow)
    sh.shadowBlurRadius = S * 0.055
    sh.shadowOffset = NSSize(width: 0, height: -S * 0.014)
    sh.set()
    bottom.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // angle: -90 → starting 落在顶端
    NSGradient(starting: top, ending: bottom)!.draw(in: body, angle: -90)
    // 顶部一层柔光，让底板不是死板的线性渐变。
    // 必须铺满整个底板高度：只铺上半，衰减到 0 的那条边会在中间留下一道横线，
    // 浅底还看得过去，深底一眼就是地板缝。
    NSGradient(starting: NSColor.white.withAlphaComponent(0.17),
               ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 内描边：一道很细的亮边，把底板从背景里"切"出来
    let inner = NSBezierPath(roundedRect: body.insetBy(dx: 1.2, dy: 1.2),
                             xRadius: r - 1.2, yRadius: r - 1.2)
    inner.lineWidth = 2.4
    NSColor.white.withAlphaComponent(rim).setStroke()
    inner.stroke()

    // 抗 banding：20 级的浅色渐变在 8bit 下会出横向条纹，撒一层几乎看不见的噪点打散它。
    // 这是深色版更明显，但浅色版也有，只是要在全屏亮度下才看得到。
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    var seed: UInt64 = 0x2545F4914F6CDD1D
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) & 0xFFFF) / 65535
    }
    for _ in 0..<42000 {
        let x = rnd() * S, y = rnd() * S
        (rnd() > 0.5 ? NSColor.white : NSColor.black)
            .withAlphaComponent(0.020).setFill()
        NSRect(x: x, y: y, width: 1.2, height: 1.2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - 基元

/// 带柔和投影地填一个形状
func dropFill(_ path: NSBezierPath, _ color: NSColor,
              shadow: CGFloat = 0.18, blur: CGFloat = 30, dy: CGFloat = -10) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = shadowInk.withAlphaComponent(shadow)
    sh.shadowBlurRadius = blur
    sh.shadowOffset = NSSize(width: 0, height: dy)
    sh.set()
    color.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// 卡片：圆角矩形，白到灰的极轻渐变，压在底板上
func card(_ rect: CGRect, radius: CGFloat,
          top: NSColor = hex(0xFFFFFF), bottom: NSColor = hex(0xF2F0EC),
          shadow: CGFloat = 0.17, blur: CGFloat = 34,
          ink: NSColor? = hex(0x2B2724), inkAlpha: CGFloat = 0.13,
          edge: CGFloat = 0.75,
          lines: [CGFloat] = [0.62, 0.44, 0.54],
          lineTop: CGFloat = 0.30,
          lineStep: CGFloat = 0.155) {

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    dropFill(path, bottom, shadow: shadow, blur: blur)

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 边缘亮线
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let rimPath = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                               xRadius: radius - 1, yRadius: radius - 1)
    rimPath.lineWidth = 2
    NSColor.white.withAlphaComponent(edge).setStroke()
    rimPath.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 抽象的"字"
    if let ink = ink, !lines.isEmpty {
        let lh = max(radius * 0.30, 12)
        for (i, w) in lines.enumerated() {
            let y = rect.maxY - rect.height * (lineTop + CGFloat(i) * lineStep)
            let rr = CGRect(x: rect.minX + rect.width * 0.17,
                            y: y - lh, width: rect.width * w, height: lh)
            ink.withAlphaComponent(inkAlpha).setFill()
            NSBezierPath(roundedRect: rr, xRadius: lh / 2, yRadius: lh / 2).fill()
        }
    }
}

/// 一只侧面看的弹簧木夹。
///
/// 真实木夹子的比例是「捏手短、夹口长」：捏手只占全长三分之一，夹口占其余。
/// 我第一版把这个比例做反了，画出来是弹弓不是夹子。三样缺一样就不成立：
/// 顶端张开、中间一根轴、末端并拢。
///
/// 上臂和下臂连成一条折线（不是两段），join 处才会是一根木头弯过去，不是两根接起来。
func peg(cx: CGFloat, coilY: CGFloat, height: CGFloat, width: CGFloat,
         upRatio: CGFloat = 0.34,
         spreadRatio: CGFloat = 0.38,
         light: NSColor, dark: NSColor,
         coil: NSColor, coilHole: NSColor,
         shadow: CGFloat = 0.22, blur: CGFloat = 26) {

    let thick = width * 0.34
    let upLen = height * upRatio
    let downLen = height * (1 - upRatio)
    // 两片木头几乎贴死，中缝只留一丝——缝一宽就变成"两条腿"，
    // 而夹子看上去应该是"一根柱子上有一条发丝缝"。
    let neck = thick * 0.505         // 轴处两条中心线的半间距
    let foot = thick * 0.53          // 夹口末端，比轴略开一点点
    let spread = width * spreadRatio

    // 两片木头：后片先画（暗一档，只露一点点），前片后画，形成厚度。
    // 捏手端是圆头（木头切口磨圆），夹口端是平头——圆头会看成两根手指按在纸上。
    for (s, back) in [(CGFloat(-1), true), (CGFloat(1), false)] {

        let hand = NSBezierPath()
        hand.move(to: NSPoint(x: cx + s * spread, y: coilY + upLen))
        hand.line(to: NSPoint(x: cx + s * neck, y: coilY))

        let jaw = NSBezierPath()
        jaw.move(to: NSPoint(x: cx + s * neck, y: coilY))
        jaw.line(to: NSPoint(x: cx + s * foot, y: coilY - downLen))

        // 两段各自描边再合并：上段要圆头、下段要平头，一条路径做不到
        let handSolid = hand.cgPath.copy(strokingWithWidth: thick, lineCap: .round,
                                         lineJoin: .round, miterLimit: 10)
        let jawSolid = jaw.cgPath.copy(strokingWithWidth: thick, lineCap: .butt,
                                       lineJoin: .round, miterLimit: 10)
        let solid = NSBezierPath(cgPath: handSolid.union(jawSolid))

        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = shadowInk.withAlphaComponent(back ? shadow * 0.5 : shadow)
        sh.shadowBlurRadius = blur
        sh.shadowOffset = NSSize(width: 0, height: -8)
        sh.set()
        dark.setFill()
        solid.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        solid.addClip()
        let g = back ? (light.blended(withFraction: 0.08, of: NSColor.black) ?? dark) : light
        NSGradient(starting: g, ending: dark)!.draw(in: solid.bounds, angle: -72)
        NSGraphicsContext.restoreGraphicsState()
    }

    // 弹簧：横着箍住整根木条的金属圈，不是一颗纽扣。
    // 它是这只夹子唯一"非木头"的东西，做得像螺丝头就会让人看成眼睛。
    let cw = thick * 2.9
    let ch = thick * 1.15
    let coilRect = CGRect(x: cx - cw / 2, y: coilY - ch * 0.55, width: cw, height: ch)
    let coilPath = NSBezierPath(roundedRect: coilRect, xRadius: ch / 2, yRadius: ch / 2)

    NSGraphicsContext.saveGraphicsState()
    let csh = NSShadow()
    csh.shadowColor = shadowInk.withAlphaComponent(0.30)
    csh.shadowBlurRadius = 14
    csh.shadowOffset = NSSize(width: 0, height: -4)
    csh.set()
    coil.setFill()
    coilPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 箍上一道细高光，让它有金属的圆
    NSGraphicsContext.saveGraphicsState()
    coilPath.addClip()
    NSGradient(starting: coilHole.withAlphaComponent(0.55),
               ending: coilHole.withAlphaComponent(0))!
        .draw(in: CGRect(x: coilRect.minX, y: coilRect.midY,
                         width: coilRect.width, height: coilRect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// 正面看的弹簧木夹：一块上宽下窄的板，顶部一个 U 形开口，腰上一道金属箍。
///
/// 之前画的是侧面，上臂张开、下臂两条腿——那是侧面才有的特征，
/// 可一旦旁边配一张正对观者的卡片，两个视角就打架，图形必然读成"站着的人"。
/// 正面视角没有"张开的臂"，只有"一个开口、一道箍、一块收窄的板"。
func frontPeg(cx: CGFloat, bottom: CGFloat, height: CGFloat, width: CGFloat,
              light: NSColor, dark: NSColor,
              coil: NSColor, coilHole: NSColor) {

    let lowerW = width * 0.86
    let lowerH = height * 0.46
    let upperH = height * 0.54
    let upperY = bottom + lowerH          // 两块严丝合缝，不重叠（evenOdd 才能一次填对）

    // 整体轮廓：下块 + 上块，两段矩形拼成一个"上宽下窄"的板
    let body = NSBezierPath(roundedRect: CGRect(x: cx - lowerW / 2, y: bottom,
                                                width: lowerW, height: lowerH),
                            xRadius: lowerW * 0.20, yRadius: lowerW * 0.20)
    body.append(NSBezierPath(roundedRect: CGRect(x: cx - width / 2, y: upperY,
                                                 width: width, height: upperH),
                             xRadius: width * 0.14, yRadius: width * 0.14))

    // 两片木头之间那条缝：细，从顶边往下切进去一小段，底部收圆。
    // 开成一个大 U 口就变成卡槽了，夹子正面看到的只是"一道缝"。
    let notchW = width * 0.11
    let notchD = height * 0.30
    let notch = NSBezierPath(roundedRect: CGRect(x: cx - notchW / 2,
                                                 y: upperY + upperH - notchD,
                                                 width: notchW, height: notchD),
                             xRadius: notchW / 2, yRadius: notchW / 2)
    body.append(notch)
    body.windingRule = .evenOdd

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = shadowInk.withAlphaComponent(0.24)
    sh.shadowBlurRadius = 26
    sh.shadowOffset = NSSize(width: 0, height: -9)
    sh.set()
    dark.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(starting: light, ending: dark)!.draw(in: body.bounds, angle: -75)
    NSGraphicsContext.restoreGraphicsState()

    // 腰上的金属箍：比下块略宽，把两段木头箍住
    let coilW = lowerW * 1.12
    let coilH = height * 0.115
    let coilRect = CGRect(x: cx - coilW / 2, y: bottom + lowerH - coilH * 0.62,
                          width: coilW, height: coilH)
    let coilPath = NSBezierPath(roundedRect: coilRect,
                                xRadius: coilH / 2, yRadius: coilH / 2)

    NSGraphicsContext.saveGraphicsState()
    let csh = NSShadow()
    csh.shadowColor = shadowInk.withAlphaComponent(0.28)
    csh.shadowBlurRadius = 14
    csh.shadowOffset = NSSize(width: 0, height: -4)
    csh.set()
    coil.setFill()
    coilPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    coilPath.addClip()
    NSGradient(starting: coilHole.withAlphaComponent(0.45),
               ending: coilHole.withAlphaComponent(0))!
        .draw(in: CGRect(x: coilRect.minX, y: coilRect.midY,
                         width: coilRect.width, height: coilRect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// 一张"照片"卡片：卡片里装着天、一个太阳、两座山。
///
/// 为什么不是三条横线：纸加横线是备忘录、TextEdit、提醒事项三家的地盘，
/// 再画一张就是第四个。太阳加山是"图片"的通用符号，对应截图这个功能，
/// 而且它在小尺寸下是三个实心块，比三条 1px 的细线活得久。
enum CardStyle { case photo, text }

func photoCard(_ rect: CGRect, radius: CGFloat,
               shadow: CGFloat = 0.20, blur: CGFloat = 34,
               skyTop: NSColor, skyBottom: NSColor,
               sun: NSColor, hillBack: NSColor, hillFront: NSColor,
               sunShift: CGFloat = 0.0,
               style: CardStyle = .photo,
               edge: CGFloat = 0.55) {

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    dropFill(path, skyBottom, shadow: shadow, blur: blur)

    NSGraphicsContext.saveGraphicsState()
    path.addClip()

    // 天空
    NSGradient(starting: skyTop, ending: skyBottom)!.draw(in: rect, angle: -90)

    switch style {
    case .photo:
        // 太阳：偏上偏左。正中间会被上面那个夹子顶住，看着像夹子戳着太阳；
        // 而且"太阳在左上、山在下面"本来就是风景照最省事的构图。
        let sr = rect.width * 0.150
        let sunC = CGPoint(x: rect.midX + rect.width * (-0.10 + sunShift),
                           y: rect.maxY - rect.height * 0.42)
        sun.setFill()
        NSBezierPath(ovalIn: CGRect(x: sunC.x - sr, y: sunC.y - sr,
                                    width: sr * 2, height: sr * 2)).fill()

        // 两座山：后一座低而宽，前一座高而窄，都压在卡片底边上
        func hill(peakX: CGFloat, peakY: CGFloat, halfW: CGFloat, color: NSColor) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: peakX - halfW, y: rect.minY))
            p.curve(to: NSPoint(x: peakX, y: peakY),
                    controlPoint1: NSPoint(x: peakX - halfW * 0.55, y: rect.minY + (peakY - rect.minY) * 0.78),
                    controlPoint2: NSPoint(x: peakX - halfW * 0.20, y: peakY))
            p.curve(to: NSPoint(x: peakX + halfW, y: rect.minY),
                    controlPoint1: NSPoint(x: peakX + halfW * 0.20, y: peakY),
                    controlPoint2: NSPoint(x: peakX + halfW * 0.55, y: rect.minY + (peakY - rect.minY) * 0.78))
            p.close()
            color.setFill()
            p.fill()
        }
        hill(peakX: rect.midX + rect.width * 0.10,
             peakY: rect.minY + rect.height * 0.42,
             halfW: rect.width * 0.40, color: hillBack)
        hill(peakX: rect.midX - rect.width * 0.13,
             peakY: rect.minY + rect.height * 0.30,
             halfW: rect.width * 0.34, color: hillFront)

    case .text:
        // 一张文字卡：几条圆角细线，宽度参差，像一段被截下来的话。
        // 用细线而不是字：图标里的小字在 16px 只会变成脏点，线还能读。
        let ink = sun.blended(withFraction: 0.62, of: hex(0x8C8479)) ?? hex(0xB0A79C)
        let lh = rect.height * 0.034
        let spec: [(CGFloat, CGFloat)] = [(0.66, 0.74), (0.80, 0.58), (0.52, 0.42), (0.70, 0.26)]
        for (w, yFrac) in spec {
            let r = CGRect(x: rect.minX + rect.width * 0.16,
                           y: rect.minY + rect.height * yFrac,
                           width: rect.width * w * 0.84,
                           height: lh)
            ink.withAlphaComponent(0.42).setFill()
            NSBezierPath(roundedRect: r, xRadius: lh / 2, yRadius: lh / 2).fill()
        }
    }

    // 边缘亮线画在最后，否则被天空盖掉
    let rimPath = NSBezierPath(roundedRect: rect.insetBy(dx: 1.2, dy: 1.2),
                               xRadius: radius - 1.2, yRadius: radius - 1.2)
    rimPath.lineWidth = 2.4
    NSColor.white.withAlphaComponent(edge).setStroke()
    rimPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - 两种夹子

/// App 里原本就有两个夹子，这里直接用，不再自己画。
///
/// 金属夹是 `PeggedView.swift` 里 `metalPill` 的那个形状：9×26 的铝胶囊，
/// 顶部一道槽让绳穿过。木夹是 `Sources/Clothespeg/Resources/Peg.png`，
/// 711×2278 的插画，带透明通道。自己照着画过四轮，都不如这两个。
let pegArtPath = "Sources/Clothespeg/Resources/Peg.png"
let pegArt: NSImage? = NSImage(contentsOfFile:
    FileManager.default.currentDirectoryPath + "/" + pegArtPath)

/// 木夹。图本身 1:3.2，细长。
///
/// 挂点定在距顶 30% 处：真夹子晾衣时绳是从顶端那道缝里穿过去的，
/// 所以大半截留在绳下面。早前用 55%（大半截竖在绳上面），看着像夹子
/// 站在绳上而不是挂在绳上。
func woodenPeg(cx: CGFloat, hangY: CGFloat, height: CGFloat) {
    guard let art = pegArt, art.size.height > 0 else { return }
    let w = height * (art.size.width / art.size.height)
    let rect = CGRect(x: cx - w / 2, y: hangY - height * 0.70,
                      width: w, height: height)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = shadowInk.withAlphaComponent(0.30)
    sh.shadowBlurRadius = height * 0.07
    sh.shadowOffset = NSSize(width: 0, height: -height * 0.03)
    sh.set()
    art.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

/// 金属夹。1:2.89 的铝胶囊，槽在距顶 35% 处。
func metalPeg(cx: CGFloat, hangY: CGFloat, height: CGFloat) {
    let w = height / 2.89
    let rect = CGRect(x: cx - w / 2, y: hangY - height * 0.65,
                      width: w, height: height)
    let r = w * 0.39
    let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = shadowInk.withAlphaComponent(0.32)
    sh.shadowBlurRadius = w * 0.55
    sh.shadowOffset = NSSize(width: 0, height: -w * 0.30)
    sh.set()
    hex(0xABABAB).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colorsAndLocations:
        (hex(0xB0B0B3), 0.0),
        (hex(0xEFEFF2), 0.35),
        (hex(0xD3D3D6), 0.65),
        (hex(0x9B9BA0), 1.0))!
        .draw(in: rect, angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    // 内描边：上亮下暗，金属才有圆
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: hex(0xFFFFFF).withAlphaComponent(0.85),
               ending: hex(0x000000).withAlphaComponent(0.18))!
        .draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: w*0.055, dy: w*0.055),
                           xRadius: r * 0.9, yRadius: r * 0.9)
    rim.lineWidth = w * 0.05
    hex(0x8A8A8E).withAlphaComponent(0.55).setStroke()
    rim.stroke()

    // 绳穿过的槽
    let slotW = w * 0.56, slotH = w * 0.16
    let slot = CGRect(x: rect.midX - slotW/2,
                      y: rect.maxY - height * 0.35 - slotH/2,
                      width: slotW, height: slotH)
    hex(0x4A4A4E).withAlphaComponent(0.42).setFill()
    NSBezierPath(roundedRect: slot, xRadius: slotH/2, yRadius: slotH/2).fill()
}

// MARK: - 场景

/// 一根晾衣绳，一个夹子咬在绳上，一张卡片从绳后面垂下来。
///
/// 绳子是这三个元素里最要紧的一个。没有它，侧面看的夹子只能靠歪二十度躲开
/// "站着的人"；有了它，夹子是被绳子挂住的物件，语境自己就成立。
///
/// 层次按物理关系排：卡片在后（所以顶边被绳压住），绳在中间，夹子在最前。
/// 夹口同时咬住绳和卡片——这样三样东西是连在一起的一件事，不是三个贴图。
func scene(plateTop: NSColor, plateBottom: NSColor,
           rim: CGFloat = 0.30, outerShadow: CGFloat = 0.24,
           ropeColor: NSColor, ropeWidth: CGFloat = 18, ropeSag: CGFloat = 104,
           cardW: CGFloat = 390, cardH: CGFloat = 404, cardBottomY: CGFloat = 258,
           cardTop: NSColor = hex(0xFFFFFF), cardBottom: NSColor = hex(0xF2F0EC),
           cardInk: NSColor = hex(0x2B2724), cardInkAlpha: CGFloat = 0.17,
           cardEdge: CGFloat = 0.75, cardShadow: CGFloat = 0.18,
           pegH: CGFloat = 246, pegW: CGFloat = 164,
           pegLight: NSColor, pegDark: NSColor,
           coil: NSColor, coilHole: NSColor) {

    plate(top: plateTop, bottom: plateBottom, outerShadow: outerShadow, rim: rim)

    let cardRect = CGRect(x: 512 - cardW / 2, y: cardBottomY, width: cardW, height: cardH)
    let ropeY = cardRect.maxY + 2           // 绳子要盖过卡片顶沿，卡片才像挂在绳后
    let upRatio: CGFloat = 0.34
    // 夹口的中段正好落在绳子上：绳和卡片一起被夹住，三样东西才是一件，
    // 而不是三张贴图叠在一起。弹簧因此落在绳子上方半个夹口的位置。
    let coilY = ropeY + pegH * (1 - upRatio) * 0.5

    // ── 卡片
    let lineCount: [CGFloat] = cardH > 420
        ? [0.52, 0.40, 0.58, 0.46, 0.34]
        : [0.60, 0.44, 0.54]
    card(cardRect, radius: 44, top: cardTop, bottom: cardBottom,
         shadow: cardShadow, blur: 34, ink: cardInk, inkAlpha: cardInkAlpha,
         edge: cardEdge, lines: lineCount, lineTop: 0.25, lineStep: 0.128)

    // ── 绳：贯穿底板，两端被圆角裁掉
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: bodyRect,
                 xRadius: bodyRect.width * 0.2245,
                 yRadius: bodyRect.width * 0.2245).addClip()

    let p0 = NSPoint(x: -60, y: ropeY + 22)
    let p1 = NSPoint(x: 292, y: ropeY - ropeSag)
    let p2 = NSPoint(x: 732, y: ropeY - ropeSag)
    let p3 = NSPoint(x: 1084, y: ropeY + 22)

    func bez(_ t: CGFloat) -> NSPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return NSPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    let rope = NSBezierPath()
    rope.move(to: p0)
    rope.curve(to: p3, controlPoint1: p1, controlPoint2: p2)
    rope.lineWidth = ropeWidth
    rope.lineCapStyle = .round

    // 绳自己的影子：不投影它就只是画上去的一条线
    NSGraphicsContext.saveGraphicsState()
    let rs = NSShadow()
    rs.shadowColor = shadowInk.withAlphaComponent(0.28)
    rs.shadowBlurRadius = 12
    rs.shadowOffset = NSSize(width: 0, height: -6)
    rs.set()
    ropeColor.setStroke()
    rope.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 捻纹：麻绳是一股股拧的，光溜溜一根只会读成铁丝。
    // 每隔一小段画一道斜切口，缩到 128 会自己糊成一条灰带，不碍事。
    NSGraphicsContext.saveGraphicsState()
    rope.addClip()
    let twist = (ropeColor.blended(withFraction: 0.30, of: NSColor.black) ?? ropeColor)
        .withAlphaComponent(0.62)
    twist.setStroke()
    var t: CGFloat = 0.004
    while t < 0.996 {
        let a = bez(t), b = bez(min(t + 0.008, 1))
        let ang = atan2(b.y - a.y, b.x - a.x)
        // 斜着切，不是垂直：麻绳是一股股斜拧的，垂直的横档读成梯子
        let slant = ang + .pi / 2 + 0.46
        let seg = NSBezierPath()
        let rx = cos(slant) * ropeWidth * 0.52
        let ry = sin(slant) * ropeWidth * 0.52
        let ox = cos(ang) * ropeWidth * 0.22
        let oy = sin(ang) * ropeWidth * 0.22
        seg.move(to: NSPoint(x: a.x - rx + ox, y: a.y - ry + oy))
        seg.line(to: NSPoint(x: a.x + rx + ox, y: a.y + ry + oy))
        seg.lineWidth = 1.7
        seg.lineCapStyle = .round
        seg.stroke()
        t += 0.0115
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()

    // ── 夹子
    peg(cx: 512, coilY: coilY, height: pegH, width: pegW, upRatio: upRatio,
        light: pegLight, dark: pegDark, coil: coil, coilHole: coilHole)
}

/// 一根下垂的麻绳，带捻纹，两端被底板圆角裁掉。
///
/// 和 scene() 里那段是同一套画法，抽出来给新场景用。没有回头改 scene()，
/// 是因为那四个方案已经定稿，不想为了复用去动它。
/// 一根晾衣绳：从 x0 挂到 x1，中间往下垂 `sag`。
///
/// 控制点固定在 1/3 与 2/3 处，x(t) 才是线性的 —— 这样 ropeYAt 能直接反算出
/// 绳在某一点的实际高度，夹子才咬得准。控制点一下移 k，中点下沉 0.75k，
/// 所以 k = sag / 0.75。
func drawRope(ropeY: CGFloat, sag: CGFloat, color: NSColor, width: CGFloat,
              x0: CGFloat, x1: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: bodyRect,
                 xRadius: bodyRect.width * 0.2245,
                 yRadius: bodyRect.width * 0.2245).addClip()

    let k = sag / 0.75
    let p0 = NSPoint(x: x0, y: ropeY)
    let p1 = NSPoint(x: x0 + (x1 - x0) / 3, y: ropeY - k)
    let p2 = NSPoint(x: x0 + (x1 - x0) * 2 / 3, y: ropeY - k)
    let p3 = NSPoint(x: x1, y: ropeY)

    func bez(_ t: CGFloat) -> NSPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return NSPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    let rope = NSBezierPath()
    rope.move(to: p0)
    rope.curve(to: p3, controlPoint1: p1, controlPoint2: p2)
    rope.lineWidth = width
    rope.lineCapStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let rs = NSShadow()
    rs.shadowColor = shadowInk.withAlphaComponent(0.28)
    rs.shadowBlurRadius = 12
    rs.shadowOffset = NSSize(width: 0, height: -6)
    rs.set()
    color.setStroke()
    rope.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    rope.addClip()
    let twist = (color.blended(withFraction: 0.30, of: NSColor.black) ?? color)
        .withAlphaComponent(0.62)
    twist.setStroke()
    var t: CGFloat = 0.004
    while t < 0.996 {
        let a = bez(t), b = bez(min(t + 0.008, 1))
        let ang = atan2(b.y - a.y, b.x - a.x)
        let slant = ang + .pi / 2 + 0.46
        let seg = NSBezierPath()
        let rx = cos(slant) * width * 0.52
        let ry = sin(slant) * width * 0.52
        let ox = cos(ang) * width * 0.22
        let oy = sin(ang) * width * 0.22
        seg.move(to: NSPoint(x: a.x - rx + ox, y: a.y - ry + oy))
        seg.line(to: NSPoint(x: a.x + rx + ox, y: a.y + ry + oy))
        seg.lineWidth = 1.7
        seg.lineCapStyle = .round
        seg.stroke()
        t += 0.0115
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

/// 取景框的四个折角：角上一段圆弧，两边各一段直边。
///
/// 早前画的是纯四分之一圆，出来是一根"逗号"，看着像笔画不像框。
/// 参考图（2026-11-04 用户给的）是 L 形折角：弧在角上、直边往两边伸。
/// 参考图的弧偏小，这里把弧放大到直边长度的六成左右，折角更软一点。
///
/// 直边的两端用平口（.butt）：圆口会把 L 的两头包成棍子，框的感觉就没了。
func arcFrame(_ rect: CGRect, thick: CGFloat, color: NSColor,
              radiusFrac: CGFloat = 0.078, armFrac: CGFloat = 0.168) {
    let s = thick / 2
    // 描边是压在路径中间的，所以路要走内缩半个线宽，描边的外沿才正好落在 rect 上
    let q = rect.insetBy(dx: s, dy: s)
    let r = min(rect.width * radiusFrac, rect.width * armFrac)
    let run = rect.width * armFrac - r   // 直边那一截的长度

    color.setStroke()
    let paths: [NSBezierPath] = [
        // 左下：从竖边往上，绕过角，再沿横边往右
        {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: q.minX, y: q.minY + r + run))
            p.line(to: NSPoint(x: q.minX, y: q.minY + r))
            p.appendArc(withCenter: NSPoint(x: q.minX + r, y: q.minY + r),
                        radius: r, startAngle: 180, endAngle: 270)
            p.line(to: NSPoint(x: q.minX + r + run, y: q.minY))
            return p
        }(),
        // 右下
        {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: q.maxX - r - run, y: q.minY))
            p.line(to: NSPoint(x: q.maxX - r, y: q.minY))
            p.appendArc(withCenter: NSPoint(x: q.maxX - r, y: q.minY + r),
                        radius: r, startAngle: 270, endAngle: 360)
            p.line(to: NSPoint(x: q.maxX, y: q.minY + r + run))
            return p
        }(),
        // 右上
        {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: q.maxX, y: q.maxY - r - run))
            p.line(to: NSPoint(x: q.maxX, y: q.maxY - r))
            p.appendArc(withCenter: NSPoint(x: q.maxX - r, y: q.maxY - r),
                        radius: r, startAngle: 0, endAngle: 90)
            p.line(to: NSPoint(x: q.maxX - r - run, y: q.maxY))
            return p
        }(),
        // 左上
        {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: q.minX + r + run, y: q.maxY))
            p.line(to: NSPoint(x: q.minX + r, y: q.maxY))
            p.appendArc(withCenter: NSPoint(x: q.minX + r, y: q.maxY - r),
                        radius: r, startAngle: 90, endAngle: 180)
            p.line(to: NSPoint(x: q.minX, y: q.maxY - r - run))
            return p
        }(),
    ]
    for p in paths {
        p.lineWidth = thick
        p.lineCapStyle = .butt
        p.lineJoinStyle = .round
        p.stroke()
    }
}

/// 两根绳上的两张照片卡：分开排，各挂一个夹子。
///
/// 一张卡是"拿着一样东西"，两张卡才是"手上有很多样东西"。这也是 App 现在
/// 的样子：截图、剪贴板、便签三件事同时在跑。
///
/// overlap 是第二张卡向左压过去的比例，0 表示完全分开、各占一半。
func sceneTwin(plateTop: NSColor, plateBottom: NSColor,
               rim: CGFloat = 0.30, outerShadow: CGFloat = 0.24,
               ropeColor: NSColor, ropeWidth: CGFloat = 12, ropeSag: CGFloat = 38,
               cardW: CGFloat = 226, cardH: CGFloat = 303,
               cardGap: CGFloat = 82, cardBottomY: CGFloat = 345,
               rightDrop: CGFloat = 10, tilt: CGFloat = 4.0,
               overlap: CGFloat = 0,
               skyTop: NSColor, skyBottom: NSColor,
               sun: NSColor, hillBack: NSColor, hillFront: NSColor,
               pegH: CGFloat = 210, pegW: CGFloat = 96,
               pegLight: NSColor, pegDark: NSColor,
               coil: NSColor, coilHole: NSColor,
               frameColor: NSColor? = nil, frameThick: CGFloat = 19,
               frameInset: CGFloat = 0.080) {

    plate(top: plateTop, bottom: plateBottom, outerShadow: outerShadow, rim: rim)

    let totalW = cardW * 2 + cardGap - cardW * overlap
    let x0 = 512 - totalW / 2
    let leftRect = CGRect(x: x0, y: cardBottomY, width: cardW, height: cardH)
    // 右边那张低一点：绳子是往下垂的，两件东西挂上去本来就不该一样高
    let rightRect = CGRect(x: x0 + cardW + cardGap - cardW * overlap,
                           y: cardBottomY - rightDrop, width: cardW, height: cardH)

    let cardTopY = max(leftRect.maxY, rightRect.maxY)
    // 绳和卡顶之间必须留出一段：这 88 就是"夹子挂着东西"的那一截。
    // 之前是 40，夹子几乎整个趴在卡上，看不出是挂上去的。
    let ropeY = cardTopY + 96
    // 两个夹子高度靠拢：早前金属 135、木头 260，一个像耳钉一个像木板。
    // 两者都按 1:2.89 与 1:3.2 的比例，都定在 180 时宽度是 62 与 56，
    // 一排看过去是同一种零件，只是颜色不同。
    // 金属夹必须够高才咬得住卡：它的挂点是固定的穿绳槽（距顶 35%），
    // 只有 65% 在绳下面；160 时只咬到卡顶 16，像挂在卡边上没夹住。
    let metalPegH: CGFloat = 158
    let woodenPegH: CGFloat = 158

    // 绳是往下垂的，两个夹子不在同一高度上。各自对准绳在该点的实际高度，
    // 否则绳会从夹子底下穿过去，看着像绳子穿过了夹子而不是夹子夹着绳子。
    // 绳只在两张卡的外沿之间，不贯穿到盘子边缘
    let ropeX0 = leftRect.minX
    let ropeX1 = rightRect.maxX

    func ropeYAt(_ x: CGFloat) -> CGFloat {
        let t = min(max((x - ropeX0) / (ropeX1 - ropeX0), 0), 1)
        return ropeY - ropeSag * 4 * t * (1 - t)
    }

    // 后画的压前面。overlap > 0 时右边那张压住左边那张的一条边。
    // 两张卡各自歪一点，方向相反：风从中间穿过去，两件东西被吹得往外撇。
    // 完全正、完全对称的两张卡看着像贴在墙上，不像挂着的。
    func tilted(_ r: CGRect, by deg: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: r.midX, yBy: r.midY)
        t.rotate(byDegrees: deg)
        t.translateX(by: -r.midX, yBy: -r.midY)
        t.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    tilted(leftRect, by: -tilt) {
        photoCard(leftRect, radius: 30, shadow: 0.20, blur: 30,
                  skyTop: skyTop, skyBottom: skyBottom, sun: sun,
                  hillBack: hillBack, hillFront: hillFront,
                  style: .photo)
    }
    tilted(rightRect, by: tilt) {
        photoCard(rightRect, radius: 30, shadow: overlap > 0 ? 0.24 : 0.20, blur: 30,
                  skyTop: skyTop, skyBottom: skyBottom, sun: sun,
                  hillBack: hillBack, hillFront: hillFront,
                  style: .text)
    }

    drawRope(ropeY: ropeY, sag: ropeSag, color: ropeColor, width: ropeWidth,
             x0: ropeX0, x1: ropeX1)

    // 图卡用金属夹，文字卡用木夹：木夹是纸的，金属夹是别的
    metalPeg(cx: leftRect.midX, hangY: ropeYAt(leftRect.midX), height: metalPegH)
    woodenPeg(cx: rightRect.midX, hangY: ropeYAt(rightRect.midX), height: woodenPegH)

    // 取景框最后画：它占着四个角，任何东西都不许压在它上面
    if let fc = frameColor {
        let fw = bodyRect.width * (1 - frameInset * 2)
        arcFrame(CGRect(x: 512 - fw / 2, y: 512 - fw / 2, width: fw, height: fw),
                 thick: frameThick, color: fc)
    }
}

// MARK: - 方案

func render(_ mode: String) {
    switch mode {

    // A 暖白 ── 跟 App 内配色同源，最稳
    case "A":
        scene(plateTop: hex(0xFDF6F0), plateBottom: hex(0xEBDACB),
              ropeColor: hex(0xA99583),
              pegLight: clayLite, pegDark: clayDeep,
              coil: hex(0x8E4430), coilHole: hex(0xFFEFE6))

    // B 暮色 ── 深底把橙色衬出来
    case "B":
        scene(plateTop: hex(0x342B26), plateBottom: hex(0x201A17),
              rim: 0.12, outerShadow: 0.34,
              ropeColor: hex(0x9B8672),
              cardTop: hex(0xFFFCF9), cardBottom: hex(0xE9E1D7),
              cardInk: hex(0x3A2F2A), cardInkAlpha: 0.18, cardEdge: 0.30,
              cardShadow: 0.42,
              pegLight: hex(0xF09A78), pegDark: hex(0xB04F33),
              coil: hex(0x7A3A28), coilHole: hex(0xFFD9C6))

    // C 陶土 ── 底色就是品牌色
    case "C":
        scene(plateTop: hex(0xDE8365), plateBottom: hex(0xAF4E2C),
              rim: 0.22, outerShadow: 0.30,
              ropeColor: hex(0x8C3F22),
              cardTop: hex(0xFFFFFF), cardBottom: hex(0xF6EEE7),
              cardInk: hex(0x8E4430), cardInkAlpha: 0.22, cardEdge: 0.55,
              cardShadow: 0.30,
              pegLight: hex(0xC06341), pegDark: hex(0x6B2C1A),
              coil: hex(0x5E2B1D), coilHole: hex(0xF3C4AC))

    // D 轻量 ── 三样都在，但都收小，留白更多，128px 下更清爽
    case "D":
        scene(plateTop: hex(0xFBF9F6), plateBottom: hex(0xE8E3DA),
              ropeColor: hex(0xA99A87), ropeWidth: 15, ropeSag: 84,
              cardW: 322, cardH: 344, cardBottomY: 312,
              cardEdge: 0.65, cardShadow: 0.15,
              pegH: 208, pegW: 140,
              pegLight: clayLite, pegDark: clayDeep,
              coil: hex(0x8E4430), coilHole: hex(0xFFEFE6))

    // E 双卡分开，橙框 ── 橙色全在框、夹、太阳上
    case "E":
        sceneTwin(plateTop: hex(0xFDF6F0), plateBottom: hex(0xEBDACB),
                  ropeColor: hex(0xA99583),
                  skyTop: hex(0xFFFFFF), skyBottom: hex(0xF7F2EB),
                  sun: clay, hillBack: hex(0xBCC6D2), hillFront: hex(0x98A4B2),
                  pegLight: hex(0xE2C39B), pegDark: hex(0xA97B4C),
                  coil: hex(0x77777A), coilHole: hex(0xE4E4E7),
                  frameColor: clayDeep)

    // F 双卡分开，深框 ── 橙色只剩夹子和太阳，框退到后面去
    case "F":
        sceneTwin(plateTop: hex(0xFDF6F0), plateBottom: hex(0xEBDACB),
                  ropeColor: hex(0xA99583),
                  skyTop: hex(0xFFFFFF), skyBottom: hex(0xF7F2EB),
                  sun: clay, hillBack: hex(0xBCC6D2), hillFront: hex(0x98A4B2),
                  pegLight: hex(0xE2C39B), pegDark: hex(0xA97B4C),
                  coil: hex(0x77777A), coilHole: hex(0xE4E4E7),
                  frameColor: hex(0x2B2724))

    // G 双卡少部分叠 ── 右边那张压住左边一条边
    case "G":
        sceneTwin(plateTop: hex(0xFDF6F0), plateBottom: hex(0xEBDACB),
                  ropeColor: hex(0xA99583), overlap: 0.18,
                  skyTop: hex(0xFFFFFF), skyBottom: hex(0xF7F2EB),
                  sun: clay, hillBack: hex(0xBCC6D2), hillFront: hex(0x98A4B2),
                  pegLight: hex(0xE2C39B), pegDark: hex(0xA97B4C),
                  coil: hex(0x77777A), coilHole: hex(0xE4E4E7),
                  frameColor: clay)

    default:
        break
    }
}

render(variant)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
