import Foundation

/// Where the notes are kept.
///
/// A file of its own rather than a corner of the history, which is the one
/// structural decision this feature makes. The history has a retention window
/// — fourteen days, applied once at launch — and that is the right rule for
/// something you copied last week and the wrong one for something you wrote
/// down to keep. Two rules about two kinds of thing in one file is how the
/// wrong rule ends up applied to the wrong half, and the failure would be
/// silent: a note that quietly stopped existing on its fifteenth day.
///
/// So nothing here is filtered for being old. The whole point of a note is
/// that it is still there tomorrow.
///
/// The attic keeps a picture as a path because the file is already on disk.
/// There is nothing on disk behind a note, so the note is what is written.
final class NoteStore {
    static let shared = NoteStore()

    /// One note, with the two things a card needs to be put back on the line:
    /// when it was last written to, and the id it had.
    ///
    /// The id is kept for the same reason the history keeps its own. A note
    /// restored with a fresh one is a stranger to the card it came from, and
    /// the next save — which keeps what it does not recognise — would write a
    /// second copy of it.
    struct Entry: Codable, Equatable {
        var payload: Payload
        var origin: Origin
        var id: UUID = UUID()
    }

    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent("Clothespeg/Notes.json")
    }

    /// Everything written down, newest first, which is the order the line
    /// shows it in.
    func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return stored
    }

    func save(_ entries: [Entry]) {
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Kept in memory either way, so the session still works and only
            // the next launch loses it — the same bargain the history makes.
            log.error("Could not save the notes: \(error.localizedDescription, privacy: .public)")
        }
    }
}
