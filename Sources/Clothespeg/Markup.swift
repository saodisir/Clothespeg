import AppKit
import UniformTypeIdentifiers

/// Opens a picture in the system Markup editor — the window macOS shows when
/// you click the thumbnail of a screenshot you have just taken. It is a
/// system extension, reached through the sharing service it registers.
///
/// This is Tendedero's bridge, back for the menu's "标注". Clothespeg removed
/// it once and faked the menu item with a copy; the faked item was a lie that
/// a right click kept telling, so the real thing is back, for the cards that
/// have a file an editor can open.
@MainActor
final class Markup: NSObject, NSSharingServiceDelegate {
    static let shared = Markup()

    /// Called with the file once the edited image has been written back, so
    /// the card on the line can redraw its thumbnail.
    var onSaved: (URL) -> Void = { _ in }

    private var editing: URL?
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    /// Which window the edit gesture lands in.
    ///
    /// Not the system Markup extension, for now. Measured on 2026-10-26: it
    /// arrives as a `SHKRemoteWindow` with styleMask 0, sitting over three
    /// full-screen dim/blur windows, its content an `NSRemoteView` drawn by
    /// the extension's own process. No title bar, so nothing to drag; the
    /// `.resizable` bit cannot be inserted (the mask reads back without it);
    /// the size is whatever the extension computed — 867 wide on a 1710 point
    /// screen, height following the picture's aspect. A focused overlay, not
    /// a document window, and the dock would not give it back.
    ///
    /// Preview shows the same file in an ordinary document window: resizable,
    /// movable, with the markup tools on its toolbar. False hands the file
    /// back to MarkupUI, whose own mark, unmoved.
    private static let opensInPreview = true

    /// Whether this file is one the system Markup editor can open: pictures
    /// and PDFs, which is what the screenshot extension takes.
    static func canEdit(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    func edit(_ url: URL) {
        guard !Markup.opensInPreview else {
            openInPreview(url)
            return
        }
        guard let service = NSSharingService(named: Markup.serviceName),
              service.canPerform(withItems: [url]) else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            return
        }
        editing = url
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: Preview, and knowing when it wrote

    private var watched: URL?
    private var watchedDate: Date?
    private var watcher: DispatchSourceFileSystemObject?

    /// The file goes to whatever opens pictures — Preview, unless something
    /// else has claimed them. Preview edits in place, so the card's thumbnail
    /// is stale the moment the file changes, and nobody tells us: the writing
    /// happened in another process. Hence the watcher below.
    private func openInPreview(_ url: URL) {
        stopWatching()
        watched = url
        watchedDate = Markup.modified(url)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(url)
        watch(url)
        log.notice("Markup opened in Preview: \(url.lastPathComponent, privacy: .public)")
    }

    /// The folder is watched, not the file: Preview saves atomically, which
    /// swaps the inode, and a source on the old one fires once and then goes
    /// quiet. A folder that is busy with other writes costs one date check
    /// per event, and the check is what decides whether to wake the line.
    private func watch(_ url: URL) {
        let fd = Darwin.open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func folderChanged() {
        guard let url = watched else { return }
        let stamp = Markup.modified(url)
        guard stamp != watchedDate else { return }
        watchedDate = stamp
        log.notice("Preview wrote back: \(url.lastPathComponent, privacy: .public)")
        onSaved(url)
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watched = nil
        watchedDate = nil
    }

    private static func modified(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    // MARK: NSSharingServiceDelegate

    /// Done was pressed. The extension hands back the edited image and the
    /// host app is the one that writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { self.save(items) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        log.notice("Markup ended without saving: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: Writing back

    private func save(_ items: [Any]) {
        guard let target = editing, let item = items.first else { return }
        editing = nil
        log.notice("Markup returned \(String(describing: type(of: item)), privacy: .public)")

        switch item {
        case let url as URL:
            write(from: url, to: target)
        case let image as NSImage:
            write(data: pngData(image), to: target)
        case let provider as NSItemProvider:
            load(provider, into: target)
        default:
            log.error("Markup returned an unexpected item")
        }
    }

    private func load(_ provider: NSItemProvider, into target: URL) {
        let types = provider.registeredTypeIdentifiers
        log.notice("Markup provider types: \(types.joined(separator: ", "), privacy: .public)")

        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { if let url { self.write(from: url, to: target) } }
            }
            return
        }
        // Prefer the original format, then any image format.
        let original = UTType(filenameExtension: target.pathExtension)?.identifier
        let imageType = types.first { $0 == original }
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        guard let imageType else { return }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            DispatchQueue.main.async { self.write(data: data, to: target) }
        }
    }

    private func write(from source: URL, to target: URL) {
        if source.standardizedFileURL == target.standardizedFileURL {
            onSaved(target)
        } else {
            write(data: try? Data(contentsOf: source), to: target)
        }
    }

    private func write(data: Data?, to target: URL) {
        guard let data else { return }
        do {
            try data.write(to: target, options: .atomic)
            onSaved(target)
        } catch {
            log.error("Could not save markup: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
