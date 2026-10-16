import Foundation

/// The folders the user asked to watch, and the tickets that keep them watched.
///
/// A watched folder is one the user picked by hand, which is what gives the
/// app the right to read it — in the sandbox literally, as a security-scoped
/// bookmark; outside it, as a matter of the same promise. Either way what is
/// kept here is the bookmark: an opaque ticket naming one folder, good across
/// launches, renewed the moment the user picks the folder again. The URL is
/// resolved from it on demand and never stored, because a URL can outlive its
/// permission and a bookmark cannot.
///
/// The store is dumb on purpose: entries in, entries out, one resolution
/// helper. Starting and stopping the watchers is the app delegate's work, and
/// the settings page is the only writer.
enum FolderWatchStore {

    /// One watched folder. `name` is kept for the settings row, so a folder
    /// that cannot be reached any more can still be named in its row — a row
    /// that says nothing is one the user cannot fix.
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        var bookmark: Data
        var enabled: Bool
        var name: String
    }

    private static let key = "folderWatchers"

    static var entries: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    /// Puts a freshly picked folder on the list. Answers nil and touches
    /// nothing when the folder is one that must not be watched: the app's own
    /// inbox and anything above or inside it. The inbox already hangs what
    /// lands there, and a watcher beside it would hang everything twice.
    static func add(_ url: URL) -> Entry? {
        guard Self.isWatchable(url) else { return nil }
        let standardized = url.standardizedFileURL.path
        // One folder, one entry: a second pick of the same place is a
        // correction, not a new watch.
        if entries.contains(where: { resolve($0)?.standardizedFileURL.path == standardized }) {
            return nil
        }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) else {
            log.error("Could not bookmark \(url.path, privacy: .public)")
            return nil
        }
        let entry = Entry(id: UUID(), bookmark: bookmark,
                          enabled: true, name: url.lastPathComponent)
        entries.append(entry)
        return entry
    }

    /// Swaps a stale entry's ticket for a fresh one, keeping its place and
    /// its on/off state. The re-pick of a folder the system moved or forgot.
    static func replace(_ id: UUID, with url: URL) -> Bool {
        guard Self.isWatchable(url) else { return false }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) else {
            log.error("Could not re-bookmark \(url.path, privacy: .public)")
            return false
        }
        entries[index].bookmark = bookmark
        entries[index].name = url.lastPathComponent
        return true
    }

    static func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    static func setEnabled(_ id: UUID, _ on: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = on
    }

    /// The folder a ticket stands for, or nil when the ticket has gone stale —
    /// the folder was moved, deleted, or the system simply forgot it.
    static func resolve(_ entry: Entry) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: entry.bookmark,
                        options: [.withSecurityScope], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    /// Whether a folder may be watched at all. The inbox — the app's own
    /// pictures folder — is out, and so is anything that contains it: those
    /// pictures hang already, and a second watcher there would hang them
    /// again.
    static func isWatchable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let inbox = Inbox.folder.standardizedFileURL.path
        guard path != inbox else { return false }
        // A folder that contains the inbox, or sits inside it, would have the
        // inbox watcher's ground covered too.
        return !path.hasPrefix(inbox + "/") && !inbox.hasPrefix(path + "/")
    }
}
