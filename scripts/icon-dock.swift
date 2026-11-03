// 把候选图标混进一排系统图标里，看它在 Dock 中的分量。
// 用法：swift scripts/icon-dock.swift <输出.png> <候选.png>

import AppKit

let out = CommandLine.arguments[1]
let candidate = CommandLine.arguments[2]

// 系统图标的路径各家不统一，按存在性挑第一个
let sys: [(String, [String])] = [
    ("Finder", ["/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"]),
    ("Safari", ["/System/Applications/Safari.app/Contents/Resources/AppIcon.icns",
                "/System/Applications/Safari.app/Contents/Resources/compass.icns"]),
    ("Notes",  ["/System/Applications/Notes.app/Contents/Resources/AppIcon.icns"]),
    ("Mail",   ["/System/Applications/Mail.app/Contents/Resources/ApplicationIcon.icns"]),
    ("Music",  ["/System/Applications/Music.app/Contents/Resources/AppIcon.icns"]),
    ("Calc",   ["/System/Applications/Calculator.app/Contents/Resources/AppIcon.icns"]),
]

func icon(_ paths: [String]) -> NSImage? {
    for p in paths where FileManager.default.fileExists(atPath: p) {
        if let i = NSImage(contentsOfFile: p) { return i }
    }
    return nil
}

let side: CGFloat = 176          // Dock 里一个图标的大小
let gap: CGFloat = 26
let pad: CGFloat = 44
var items: [NSImage?] = []
for (_, p) in sys { items.append(icon(p)) }
items.insert(NSImage(contentsOfFile: candidate), at: 3)   // 插在中间，前后都有系统图标

let W = pad * 2 + CGFloat(items.count) * side + CGFloat(items.count - 1) * gap
let H = side + pad * 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high

// 桌面壁纸那样的中性底色，比纯黑更能看出图标的明度
NSColor(srgbRed: 0.16, green: 0.15, blue: 0.17, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// Dock 条
let bar = NSRect(x: 16, y: 16, width: W - 32, height: H - 32)
NSColor(srgbRed: 0.78, green: 0.77, blue: 0.80, alpha: 0.16).setFill()
NSBezierPath(roundedRect: bar, xRadius: 34, yRadius: 34).fill()
NSColor.white.withAlphaComponent(0.10).setStroke()
let rim = NSBezierPath(roundedRect: bar.insetBy(dx: 1, dy: 1), xRadius: 33, yRadius: 33)
rim.lineWidth = 2
rim.stroke()

for (i, img) in items.enumerated() {
    let x = pad + CGFloat(i) * (side + gap)
    let r = NSRect(x: x, y: pad, width: side, height: side)
    if let img = img {
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    } else {
        NSColor.gray.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: r, xRadius: side * 0.22, yRadius: side * 0.22).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
