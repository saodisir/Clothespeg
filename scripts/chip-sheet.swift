// 把候选符号按截屏浮条的真实规格画成一张对比表。
//
// 为什么必须连字母一起画：浮条的 chip 是 30×26，符号 14pt 居中，快捷键 6.5pt
// 压在右下角（maxX-3, minY+2）。光看符号本身会漏掉「右下角有没有东西」这一层，
// 而这一层正好是退掉 `translate` 的原因。
//
// 用法：swift scripts/chip-sheet.swift <输出.png>

import AppKit

let out = CommandLine.arguments[1]

/// 符号 + 一句话说它画的是什么。顺序就是表里的顺序。
let candidates: [(String, String)] = [
    ("character.bubble", "气泡里一个字符（现在翻译用的，要搬去「识别文字」）"),
    ("text.bubble", "气泡里三行字"),
    ("text.bubble.fill", "同上，实心"),
    ("character.bubble.fill", "实心气泡字符（与空心配成一对）"),
    ("character.book.closed", "字典"),
    ("character.book.closed.fill", "字典，实心"),
    ("globe", "地球"),
    ("globe.asia.australia", "东亚地球"),
    ("textformat", "Aa 字型"),
    ("arrow.left.arrow.right", "左右互换"),
    ("quote.bubble", "引号气泡"),
    ("captions.bubble", "字幕气泡"),
    ("character.textbox", "字符输入框"),
    ("character.cursor.ibeam", "字符 + 输入光标"),
    ("character", "一个字符"),
    ("abc", "abc"),
    ("translate", "老图标：两个气泡，后一个正压在右下角"),
]

let scale: CGFloat = 6
let chipW = 30 * scale, chipH = 26 * scale
let colW: CGFloat = 470, rowH: CGFloat = 226
let cols = 3
let rows = (candidates.count + cols - 1) / cols
let pad: CGFloat = 40
let W = pad * 2 + CGFloat(cols) * colW
let H = pad * 2 + CGFloat(rows) * rowH + 40

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high

NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

/// 一个 chip：圆角底、符号居中、字母压右下。照 `CaptureOverlay.drawChip` 抄的。
func drawChip(_ rect: NSRect, symbol: String, key: String, light: Bool) {
    let box = NSBezierPath(roundedRect: rect, xRadius: 7 * scale, yRadius: 7 * scale)
    let ground = light ? NSColor(srgbRed: 0.961, green: 0.961, blue: 0.953, alpha: 1)
                       : NSColor(srgbRed: 0.082, green: 0.082, blue: 0.082, alpha: 1)
    ground.setFill()
    box.fill()
    let ink = light ? NSColor.black.withAlphaComponent(0.92)
                    : NSColor.white.withAlphaComponent(0.92)
    (light ? NSColor.black : NSColor.white).withAlphaComponent(0.10).setFill()
    box.fill()

    if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 14 * scale, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        if let image = base.withSymbolConfiguration(config) ?? base as NSImage? {
            let size = image.size
            image.draw(in: NSRect(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
    } else {
        print("missing symbol: \(symbol)")
        let question = NSAttributedString(string: "?", attributes: [
            .font: NSFont.systemFont(ofSize: 14 * scale),
            .foregroundColor: NSColor.systemRed,
        ])
        question.draw(at: NSPoint(x: rect.midX - 6 * scale, y: rect.midY - 9 * scale))
    }

    let hint = NSAttributedString(string: key, attributes: [
        .font: NSFont.systemFont(ofSize: 6.5 * scale, weight: .semibold),
        .foregroundColor: ink.withAlphaComponent(0.5),
    ])
    hint.draw(at: NSPoint(x: rect.maxX - hint.size().width - 3 * scale,
                          y: rect.minY + 2 * scale))
}

for (index, candidate) in candidates.enumerated() {
    let col = index % cols, row = index / cols
    let x = pad + CGFloat(col) * colW
    let y = H - pad - 40 - CGFloat(row + 1) * rowH + 30

    let name = NSAttributedString(string: candidate.0, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ])
    name.draw(at: NSPoint(x: x, y: y + chipH + 16))
    let note = NSAttributedString(string: candidate.1, attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.5),
    ])
    note.draw(at: NSPoint(x: x, y: y + chipH + 16 + 24))

    drawChip(NSRect(x: x, y: y, width: chipW, height: chipH),
             symbol: candidate.0, key: "T", light: true)
    drawChip(NSRect(x: x + chipW + 24, y: y, width: chipW, height: chipH),
             symbol: candidate.0, key: "T", light: false)
}

let legend = NSAttributedString(string: "左：浅色浮条   右：深色浮条   每格都是真实的 30×26 与 14pt 符号，右下角 6.5pt 是 T",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 16),
                                    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                                ])
legend.draw(at: NSPoint(x: pad, y: pad - 10))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
