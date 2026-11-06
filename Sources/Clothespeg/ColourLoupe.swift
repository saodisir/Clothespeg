import AppKit

/// The magnifier both the editor and the capture use while a colour is being
/// chosen. Eleven pixels around the pointer, enlarged on a grid, with the one
/// a click would label outlined and its hex written underneath.
///
/// It lives outside either view because the two of them have to agree: a
/// colour read through one magnifier and read through a different one is a
/// colour nobody can compare. The neighbourhood itself comes from
/// `ColourSampler`, so the sample and the picture of it cannot drift apart.
/// 100 pt across rather than the first 120: on a real screen the larger disc
/// read as a second window rather than a reading of one pixel.
enum ColourLoupe {
    static let radius: CGFloat = 50
    static let cells = 11
    static let hexHeight: CGFloat = 18
    static let hexGap: CGFloat = 6

    /// The disc sits up and to the right of the pointer rather than over it.
    /// The system crosshair stays visible — hiding it would mean a global
    /// hide/unhide pair that can be left unbalanced when a window loses focus —
    /// so the cursor keeps marking the exact pixel and the loupe only reads it.
    static func centre(for hover: NSPoint, in bounds: NSRect) -> NSPoint {
        let r = radius
        let margin: CGFloat = 10
        let wanted = CGPoint(x: hover.x + 66, y: hover.y + 66)
        func clamped(_ value: CGFloat, from lower: CGFloat, to upper: CGFloat) -> CGFloat {
            guard lower <= upper else { return (lower + upper) / 2 }
            return min(max(value, lower), upper)
        }
        return CGPoint(
            x: clamped(wanted.x, from: r + margin, to: bounds.width - r - margin),
            y: clamped(wanted.y,
                       from: r + hexHeight + hexGap + margin,
                       to: bounds.height - r - margin))
    }

    /// The disc, its shadow and the hex capsule underneath it — the rectangle
    /// the editor has to repaint when the loupe moves or goes away.
    ///
    /// ⚠️ This covers the loupe and nothing else. The editor is the only view
    /// that uses it for a partial repaint; the capture's aiming state repaints
    /// the whole screen (`CaptureSurface.moveColourHover(to:)`). A partial
    /// repaint there once left a trail of stale rings, and a full repaint is
    /// cheap insurance against the next thing added to that state.
    static func rect(at hover: NSPoint, in bounds: NSRect) -> NSRect {
        let centre = centre(for: hover, in: bounds)
        let r = radius + 10
        let below = hexHeight + hexGap + 10
        return NSRect(x: centre.x - r, y: centre.y - r - below,
                      width: r * 2, height: r * 2 + below)
    }

    static func draw(in ctx: CGContext, neighbourhood: ColourSampler.Neighbourhood,
                     centre: NSPoint) {
        let r = radius
        let circle = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
        let cell = circle.width / CGFloat(cells)

        ctx.saveGState()
        // A shadow under the disc, then none for anything drawn inside it.
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.addEllipse(in: circle)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)

        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        // Nearest neighbour, so eleven pixels stay eleven visible squares.
        ctx.interpolationQuality = .none
        ctx.draw(neighbourhood.image, in: circle)

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(0.5)
        for index in 1..<cells {
            let offset = CGFloat(index) * cell
            ctx.move(to: CGPoint(x: circle.minX + offset, y: circle.minY))
            ctx.addLine(to: CGPoint(x: circle.minX + offset, y: circle.maxY))
            ctx.move(to: CGPoint(x: circle.minX, y: circle.minY + offset))
            ctx.addLine(to: CGPoint(x: circle.maxX, y: circle.minY + offset))
        }
        ctx.strokePath()

        // A dark square inside a white one: the pixel a click would label
        // stays visible on both a white and a black picture.
        let target = CGRect(x: circle.midX - cell / 2, y: circle.midY - cell / 2,
                            width: cell, height: cell)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(target)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(target.insetBy(dx: 1, dy: 1))
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.addEllipse(in: circle)
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addEllipse(in: circle)
        ctx.strokePath()

        // The same dark capsule the tag left on the picture will use.
        let text = NSAttributedString(string: ColourSampler.hex(neighbourhood.centre),
                                      attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let capsule = CGRect(x: centre.x - 38,
                             y: circle.minY - hexGap - hexHeight,
                             width: 76, height: hexHeight)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
        ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: 10, cornerHeight: 10,
                           transform: nil))
        ctx.fillPath()
        text.draw(at: CGPoint(x: capsule.midX - size.width / 2,
                              y: capsule.midY - size.height / 2))
        ctx.restoreGState()
    }
}
