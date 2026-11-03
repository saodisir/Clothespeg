import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The picture being edited, and the marks on it.
///
/// The document outlives the window: close the editor with marks on the
/// picture and the marks are still here when it reopens, because the window is
/// the view of the document rather than the document itself. What it does not
/// do is outlive the app. Saving writes the marks into the pixels and forgets
/// them, which is the deal the first version makes: no sidecar file, no second
/// source of truth, no editor that can be reopened a month later to find its
/// arrows still editing a picture that has since been cropped elsewhere.
final class EditorDocument {
    /// The picture as it was when the editor opened it, or as it was after the
    /// last crop. Never drawn over: every export and every redraw starts from
    /// this and adds the marks.
    ///
    /// A `var` because cropping replaces it. Cropping a `CGImage` is a new
    /// window onto the same decoded pixels rather than a re-encode, so nothing
    /// is lost by holding the cropped picture here instead of keeping a
    /// rectangle beside the original and subtracting it everywhere.
    private(set) var source: CGImage
    /// Its size in pixels, which is the coordinate space every mark uses.
    var pixelSize: CGSize { CGSize(width: source.width, height: source.height) }
    /// The marks, oldest first.
    private(set) var marks: [EditorMark] = []

    /// Everything a step of history has to put back.
    ///
    /// The picture is in here because cropping moves it: restoring the marks
    /// without the picture they were drawn on would leave every arrow pointing
    /// at the wrong part of the frame.
    private struct State {
        var source: CGImage
        var marks: [EditorMark]

        var pixelSize: CGSize { CGSize(width: source.width, height: source.height) }
    }

    /// The states `undo` walks back through. Whole states rather than a command
    /// per edit: a mark is a small object, the line holds at most a handful per
    /// picture, and a snapshot cannot be wrong about what an edit touched —
    /// which a hand-written inverse of every operation can.
    private var past: [State] = []
    private var future: [State] = []

    init(source: CGImage) {
        self.source = source
    }

    /// The picture reduced to blocks and blown back up, for the mosaic brush.
    ///
    /// Made on demand and kept until the picture changes shape, which cropping
    /// The picture reduced to blocks, one pixel per block — not the reduction
    /// blown back up.
    ///
    /// Keeping the small one and letting the brush stretch it with nearest
    /// neighbour gives the same hard-edged result for a two-hundredth of the
    /// memory: a 5000 × 3000 screenshot is 60 MB as a full-size bitmap and
    /// 230 KB as a reduced one, and a handful of block sizes are alive at once.
    ///
    /// Sixteen is the smallest block that still reads as "deliberately hidden"
    /// rather than "badly compressed" — below that, small text survives and the
    /// tool stops being a redaction.
    private var pixelCaches: [Int: CGImage] = [:]
    private var pixelOrder: [Int] = []

    func pixelated(block: CGFloat) -> CGImage? {
        let step = max(2, Int(block.rounded()))
        if let cached = pixelCaches[step] { return cached }
        let width = max(1, source.width / step)
        let height = max(1, source.height / step)
        guard let small = CGContext(data: nil, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // High quality down, deliberately: averaging the pixels in a block is
        // what makes the block a summary of what it hides rather than one
        // unlucky pixel from the corner of it.
        small.interpolationQuality = .high
        small.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let made = small.makeImage() else { return nil }
        pixelCaches[step] = made
        pixelOrder.append(step)
        while pixelOrder.count > 4, let oldest = pixelOrder.first {
            pixelOrder.removeFirst()
            pixelCaches[oldest] = nil
        }
        return made
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// A past state, not a past view of the present.
    ///
    /// The marks are classes so they can be dragged in place, which means an
    /// array of references would be a second view of the same objects: move a
    /// rectangle and every snapshot moves with it, and undo becomes a button
    /// that does nothing. Copying is what makes the stack a history.
    private func snapshot() -> State {
        State(source: source, marks: marks.map { $0.clone() })
    }

    /// When the last snapshot was pushed, and what for. A slider sends a change
    /// per pixel of travel; twelve undo steps for one decision is not a
    /// history, it is a nuisance. A matching tag inside a moment counts as the
    /// same edit — and the "and" is what keeps it honest, because two separate
    /// width changes a minute apart are two.
    private var lastTag: String?
    private var lastEdit: Date = .distantPast

    /// Call once, before a gesture that changes a mark in place. A drag is one
    /// edit however many positions it reports, so this belongs at the start of
    /// the drag rather than in the middle of it.
    ///
    /// The tag is for the changes that are not gestures: a colour well left
    /// open reports every shade the mouse crosses, and all of them together are
    /// one decision about one mark.
    func beginEdit(tag: String? = nil) {
        if let tag, tag == lastTag, Date().timeIntervalSince(lastEdit) < 1.2 {
            lastEdit = Date()
            future.removeAll()
            return
        }
        past.append(snapshot())
        future.removeAll()
        lastTag = tag
        lastEdit = Date()
    }

    /// Adds a finished mark. The caller has already decided it is worth
    /// keeping; a click that produced a two-pixel rectangle is not.
    func add(_ mark: EditorMark) {
        beginEdit()
        marks.append(mark)
    }

    func remove(_ mark: EditorMark) {
        beginEdit()
        marks.removeAll { $0 === mark }
    }

    func undo() {
        guard let previous = past.popLast() else { return }
        future.append(snapshot())
        apply(previous)
        lastTag = nil
    }

    func redo() {
        guard let next = future.popLast() else { return }
        past.append(snapshot())
        apply(next)
        lastTag = nil
    }

    private func apply(_ state: State) {
        source = state.source
        marks = state.marks
        // Whatever mosaic marks came back carry their own copy of the pixelated
        // picture, sized for the state they were saved in, so the caches are only
        // wrong for strokes that have not been drawn yet. Dropping them means the
        // next one is built from the picture that is actually here.
        pixelCaches.removeAll()
        pixelOrder.removeAll()
    }

    /// Trims the picture to `rect`, in the picture's own pixels.
    ///
    /// The marks come with it: a crop is a new origin, and every mark's
    /// coordinates are measured from the old one. Marks left entirely outside
    /// are dropped rather than kept off-canvas, where they could never be seen
    /// or picked up again — undo brings them back along with everything else.
    ///
    /// Returns whether anything happened, so a crop to the full frame does not
    /// mark the picture dirty and send the user through the save prompt for it.
    @discardableResult
    func crop(to rect: CGRect) -> Bool {
        let whole = CGRect(origin: .zero, size: pixelSize)
        let target = rect.intersection(whole).integral
        guard target.width >= 1, target.height >= 1, target != whole,
              let cropped = source.cropping(to: target) else { return false }

        beginEdit()
        marks.removeAll { $0.bounds.intersects(target) == false }
        let shift = CGSize(width: -target.minX, height: -target.minY)
        for mark in marks { mark.translated(by: shift) }
        source = cropped
        pixelCaches.removeAll()
        pixelOrder.removeAll()

        // A mosaic paints from a copy of the pixelated picture, stretched to the
        // size it was built for. Cropping changes both, so each mark's copy is
        // rebuilt at its own block size rather than left to smear the wrong part
        // of the frame. Only when a mosaic is actually on the picture.
        for case let mosaic as MosaicMark in marks {
            guard let layer = pixelated(block: mosaic.style.blockSize) else { continue }
            mosaic.layer = layer
            mosaic.pixelSize = pixelSize
        }
        return true
    }

    /// Everything drawn together: the picture as it will be written.
    func flattened() -> CGImage? {
        EditorRenderer.flatten(self)
    }
}

/// The one place a picture plus its marks becomes pixels.
///
/// Two callers, one implementation: the canvas draws the marks in image space
/// under a scale, and the export draws them in image space at scale 1. The
/// scaling lives in the caller's transform, which is why nothing in a mark
/// multiplies by the zoom — a two-pixel line stays two pixels of the file at
/// every window size.
enum EditorRenderer {
    /// The picture and its marks as one bitmap, at the picture's own size.
    static func flatten(_ doc: EditorDocument) -> CGImage? {
        let width = Int(doc.pixelSize.width)
        let height = Int(doc.pixelSize.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let full = CGRect(origin: .zero, size: doc.pixelSize)
        ctx.draw(doc.source, in: full)
        drawMarks(doc.marks, in: ctx, scale: 1)
        return ctx.makeImage()
    }

    /// The marks alone, in image pixels, at `scale`.
    ///
    /// The caller has already moved the origin to the picture's bottom-left
    /// corner; this only scales, so a mark never has to know whether it is
    /// being drawn for the window or for the file.
    ///
    /// `skipping` is a mark that is drawn by something else — the text being
    /// typed into is drawn by the caret field — and it is counted even though
    /// it is not drawn. A number's position in the sequence comes from the list
    /// it is in, not from how many marks happen to have been drawn so far, and
    /// counting only what is drawn would number the second disc "1" the moment
    /// the first one was hidden.
    static func drawMarks(_ marks: [EditorMark], in ctx: CGContext, scale: CGFloat,
                          skipping: EditorMark? = nil) {
        guard scale > 0 else { return }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        // Numbered discs are counted here rather than stored with a number of
        // their own: delete the second of four and the rest renumber, and the
        // exported picture counts the same way because it comes through here.
        var counting = 0
        for mark in marks {
            if let numbered = mark as? NumberedMark {
                counting += 1
                numbered.number = counting
            }
            if mark !== skipping {
                mark.draw(in: ctx)
            }
        }
        ctx.restoreGState()
    }
}

/// Reading a picture and writing one back.
enum EditorStore {
    /// Loads the picture from disk, honouring the file's own orientation so a
    /// photograph taken sideways is edited the way it was seen.
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary) else { return nil }
        // A picture with an orientation tag is stored unrotated and turned by
        // every viewer. Rotated here rather than carried around, because a
        // mark drawn over a turned picture would be turned with it.
        let orientation = orientationOf(src)
        return orientation == 1 ? image : rotated(image, orientation: orientation) ?? image
    }

    private static func orientationOf(_ src: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let value = props[kCGImagePropertyOrientation] as? NSNumber else { return 1 }
        return value.intValue
    }

    /// The four quarter turns and their mirrors, applied by drawing rather
    /// than by re-encoding the pixels.
    private static func rotated(_ image: CGImage, orientation: Int) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let upright = orientation >= 5   // 5–8 swap the axes
        let size = upright ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        switch orientation {
        case 2: ctx.scaleBy(x: -1, y: 1)
        case 3: ctx.rotate(by: .pi)
        case 4: ctx.scaleBy(x: 1, y: -1)
        case 5: ctx.rotate(by: -.pi / 2); ctx.scaleBy(x: -1, y: 1)
        case 6: ctx.rotate(by: -.pi / 2)
        case 7: ctx.rotate(by: .pi / 2); ctx.scaleBy(x: -1, y: 1)
        case 8: ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// Writes the picture over its own file, keeping the file's format.
    ///
    /// The format is read from the extension rather than from the image,
    /// because the extension is what every other app on the machine will use
    /// to decide how to open it. A PNG that was edited stays a PNG.
    static func write(_ image: CGImage, to url: URL) throws {
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw EditorError.cannotWrite(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EditorError.cannotWrite(url) }
    }

    /// Keeps the picture as it was before the editor touched it.
    ///
    /// A copy rather than an overwrite-in-place with a sibling `.bak`: the
    /// folder these pictures live in is the app's own, and a file with a name
    /// the user did not choose sitting next to every edited screenshot is
    /// clutter they have to clean up. This one is out of the way and still
    /// findable — `~/Library/Application Support/Clothespeg/EditorBackups`.
    @discardableResult
    static func backup(_ url: URL) -> URL? {
        guard let folder = supportFolder("EditorBackups") else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = url.deletingPathExtension().lastPathComponent
        let copy = folder.appendingPathComponent("\(name)-\(stamp).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// The picture with nothing drawn on it.
    ///
    /// Written once, the first time a picture is opened, and never
    /// overwritten. That first opening is the only moment the file is known to
    /// be free of this app's marks: `Done` bakes them into the same file, so
    /// the second session's picture already has the first session's arrows on
    /// it. Keeping this copy is what stops the original from being spent — and
    /// it costs nothing today because nothing reads it back yet.
    static func keepBase(_ image: CGImage, for url: URL) {
        guard let folder = supportFolder("EditorBases") else { return }
        let target = folder.appendingPathComponent(baseName(for: url))
        guard FileManager.default.fileExists(atPath: target.path) == false else { return }
        try? write(image, to: target)
    }

    /// The picture as it was before anything was drawn on it, when that copy
    /// exists. Nil for every picture edited before this was kept.
    static func base(for url: URL) -> CGImage? {
        guard let folder = supportFolder("EditorBases") else { return nil }
        let target = folder.appendingPathComponent(baseName(for: url))
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return load(target)
    }

    /// A name that survives the picture being older than the copy.
    ///
    /// Two files called `image.png` in different folders would otherwise share
    /// one base, and the second would be shown the first one's pixels. The
    /// fingerprint is of the path, so it is stable for as long as the file
    /// stays where it is — which is the same condition under which the base is
    /// worth anything.
    private static func baseName(for url: URL) -> String {
        var hash: UInt32 = 2166136261
        for byte in url.path.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        let name = url.deletingPathExtension().lastPathComponent
        return "\(name)-\(String(hash, radix: 16)).png"
    }

    private static func supportFolder(_ name: String) -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Clothespeg/\(name)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        return folder
    }
}

enum EditorError: LocalizedError {
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .cannotWrite(let url):
            return L("Could not write") + " " + url.lastPathComponent
        }
    }
}
