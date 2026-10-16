import Foundation

/// Watches a folder the user chose, and hangs the new pictures it receives.
///
/// The screenshot inbox watches a folder this app owns; this watcher is the
/// general case, where the folder belongs to somebody else and the app was
/// let in by an explicit choice. That choice is a bookmark — the sandbox's
/// ticket for one folder, kept by `FolderWatchStore` — and it is cashed in
/// here, each time the watcher starts, for the access the reading needs.
/// Outside the sandbox the same calls cost nothing, so one implementation
/// serves both.
///
/// The mechanics are the screenshot watcher's: the folder's own file
/// descriptor carries the news, the listing that follows waits a fifth of a
/// second for the write to finish, and the first listing adopts what was
/// already there rather than hanging a surprise. Only pictures are watched —
/// the promise is the one the settings page makes: new images hang.
@MainActor
final class FolderWatcher {
    private let entry: FolderWatchStore.Entry
    private let onNew: (URL) -> Void
    private var known: Set<String>?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// A folder listing that is still on its way, off the main thread.
    private var listing = false
    /// A picture landed while that listing was in flight.
    private var missed = false
    /// `stop()` arrived while one of the two was still pending.
    private var stopped = false
    /// The folder while its ticket is cashed in; the scope must be given
    /// back before the watcher can be said to be gone.
    private var scopeURL: URL?
    /// Set when the folder could not be opened or read: the settings page
    /// re-asks the entry and offers a re-pick.
    private(set) var isStale = false

    /// The kinds of file the promise covers. Constant, and read from the
    /// listing's thread, so it answers to nobody's actor.
    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    init(entry: FolderWatchStore.Entry, onNew: @escaping (URL) -> Void) {
        self.entry = entry
        self.onNew = onNew
    }

    /// Cashes the ticket in and opens the folder off the main thread. A
    /// ticket that no longer resolves is staleness, not failure: the watcher
    /// says so and stays down until the folder is picked again.
    func start() {
        stopped = false
        guard source == nil else { return }
        guard let url = FolderWatchStore.resolve(entry) else {
            isStale = true
            log.error("Watched folder is no longer reachable: \(self.entry.name, privacy: .public)")
            return
        }
        // The scope answers at once and is cheap, but the open it protects
        // is the call that could block, and that one stays off the main
        // thread — the habit the screenshot watcher keeps.
        scopeURL = url
        let scoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fd = open(url.path, O_EVTONLY)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.watch(fd) }
            }
        }
    }

    /// Safe to call while `start()` or a listing is still pending: the file
    /// descriptor is closed as soon as it arrives, a listing that lands
    /// afterwards is dropped, and the ticket is given back exactly once.
    func stop() {
        stopped = true
        missed = false
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        if let url = scopeURL {
            scopeURL = nil
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func watch(_ fd: Int32) {
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard fd >= 0 else {
            isStale = true
            log.error("Cannot watch \(self.entry.name, privacy: .public)")
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
        // Writes land as a hidden temp file renamed into place; give it a
        // moment, the same fifth of a second the inbox watcher allows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Reads the folder off the main thread, one filesystem call per file.
    private func refresh() {
        guard !listing else {
            missed = true
            return
        }
        listing = true
        guard let folder = scopeURL else {
            listing = false
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]))?.filter { self.isCandidate($0) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.adopt(files) }
            }
        }
    }

    /// Takes a finished listing, reports what is new, then runs the listing
    /// that was asked for while this one was in flight. The first listing is
    /// its own baseline: whatever the folder held when the watch began was
    /// there before the watch, and none of it hangs.
    private func adopt(_ files: [URL]) {
        listing = false
        guard !stopped else { return }
        let base = known ?? Set(files.map(\.path))
        for url in files where !base.contains(url.path) {
            onNew(url)
        }
        known = Set(files.map(\.path))
        if missed {
            missed = false
            refresh()
        }
    }

    /// Runs on the listing's thread, off the main actor: an extension check
    /// needs no state the actor owns.
    private nonisolated func isCandidate(_ url: URL) -> Bool {
        Self.imageExtensions.contains(url.pathExtension.lowercased())
    }
}
