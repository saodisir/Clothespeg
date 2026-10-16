import Foundation

/// Watches the folder macOS saves screenshots into and hangs the new ones.
///
/// This is Tendedero's watcher, back by invitation. The switch is the menu's
/// "Hang new screenshots", and it is off until the user asks for it: the
/// inbox mode it serves moves where macOS saves screenshots system-wide, and
/// that is a thing to be asked for, never a thing to find running.
///
/// The folder watched is this app's own — `Inbox.folder` — which is why the
/// whole folder is trusted: every image in it is either a capture macOS wrote
/// or a copy this app wrote, and screen recordings land there too when the
/// inbox is on. Because the folder belongs to the app, watching it asks for
/// no permission; the consent dance Tendedero danced for the Desktop never
/// happens.
///
/// The folder system has no change notification, so the folder's own file
/// descriptor carries the news: a `DispatchSource` fires when macOS writes a
/// hidden temp file and renames it into place, and the listing that follows
/// waits a fifth of a second for the rename to finish.
@MainActor
final class ScreenshotWatcher {
    let folder: URL
    private var known: Set<String>?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// A `start()` that is still waiting on the folder, off the main thread.
    private var starting = false
    /// A folder listing that is still on its way, off the main thread.
    private var listing = false
    /// A capture landed while that listing was in flight.
    private var missed = false
    /// `stop()` arrived while one of the two was still pending.
    private var stopped = false
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]
    /// Screen recordings land in the folder too when the inbox is on. They
    /// hang as files: a recording has no picture to show, and a file card
    /// drags out as the recording itself.
    private static let recordingExtensions: Set<String> = ["mov", "mp4"]

    init(folder: URL, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.folder = folder
        self.onNew = onNew
        self.onChange = onChange
    }

    /// Anything created before the app launched was in the folder when the
    /// watcher first looked, and the first listing adopts it silently rather
    /// than hanging a surprise. Copies this app wrote on an earlier launch are
    /// already on the line and named by its history; a capture made while the
    /// app was closed waits there for `Inbox.sweep`, which tidies it away if
    /// no card ever claims it.
    private let launchDate = Date()

    /// The folder is opened off the main thread. Opening a folder this app
    /// owns never blocks on a consent prompt, but the cost of being wrong
    /// about that is an app that never finished launching, so the habit from
    /// Tendedero stays.
    func start() {
        stopped = false
        guard source == nil, !starting else { return }
        starting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fd = open(self.folder.path, O_EVTONLY)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.watch(fd) }
            }
        }
    }

    /// Safe to call while `start()` or a listing is still pending: the file
    /// descriptor is closed as soon as it arrives, and a listing that lands
    /// afterwards is dropped.
    func stop() {
        stopped = true
        missed = false
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func watch(_ fd: Int32) {
        starting = false
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard fd >= 0 else {
            log.error("Cannot watch \(self.folder.path, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        refresh()
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Reads the folder off the main thread. Sorting by creation date and
    /// reading it back costs one filesystem call per file, and none of it
    /// belongs on the main thread.
    private func refresh() {
        guard !listing else {
            missed = true
            return
        }
        listing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let files = self.listFolder()
            let settled = files.filter { self.creationDate($0) < self.launchDate }
            let candidates = files.filter { self.isCandidate($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.adopt(files, settled, candidates) }
            }
        }
    }

    /// Takes a finished listing, reports what is new, then runs the listing
    /// that was asked for while this one was in flight.
    private func adopt(_ files: [URL], _ settled: [URL], _ candidates: [URL]) {
        listing = false
        guard !stopped else { return }
        // The first listing adopts everything that was already there when the
        // app launched. Later ones compare against the previous listing.
        let first = known == nil
        let base = known ?? Set(settled.map(\.path))
        for url in candidates where !base.contains(url.path) {
            onNew(url)
        }
        known = Set(files.map(\.path))
        if !first { onChange() }
        if missed {
            missed = false
            refresh()
        }
    }

    private func listFolder() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.imageExtensions.contains(ext) || Self.recordingExtensions.contains(ext)
    }
}
