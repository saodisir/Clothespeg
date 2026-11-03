// 把四个方案拼成一张对比图，顺带给一排小尺寸——图标最后是活在 32px 里的。
// 用法：swift scripts/icon-sheet.swift <输出.png> <方案png...>

import AppKit

let out = CommandLine.arguments[1]
let inputs = Array(CommandLine.arguments.dropFirst(2))
let labels = ["A 暖白", "B 暮色", "C 陶土", "D 极简"]

let cell: CGFloat = 560
let gap: CGFloat = 56
let W = cell * 2 + gap * 3
let H = cell * 2 + gap * 3 + 170

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high

// 背景用深灰，浅底和深底两个方向都能看清
NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

for (i, path) in inputs.enumerated() {
    let col = i % 2, row = i / 2
    let x = gap + CGFloat(col) * (cell + gap)
    let y = H - gap - CGFloat(row + 1) * cell - CGFloat(row) * gap - 100

    guard let img = NSImage(contentsOfFile: path) else { continue }
    img.draw(in: NSRect(x: x, y: y, width: cell, height: cell),
             from: .zero, operation: .sourceOver, fraction: 1)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 26, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.80)
    ]
    (labels[i] as NSString).draw(at: NSPoint(x: x + 8, y: y - 44), withAttributes: attrs)
}

// 底部一排：32 / 64 / 128 的真实尺寸，看它小下去还成不成立
if let first = inputs.first, let img = NSImage(contentsOfFile: first) {
    var x = gap
    for side in [128.0, 64.0, 32.0] {
        img.draw(in: NSRect(x: x, y: gap, width: side, height: side),
                 from: .zero, operation: .sourceOver, fraction: 1)
        x += side + 34
    }
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.55)
    ]
    ("128 / 64 / 32 px" as NSString).draw(at: NSPoint(x: x + 16, y: gap + 44),
                                          withAttributes: attrs)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
