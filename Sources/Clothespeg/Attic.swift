import Foundation

/// Everything that has been hung, older than the line as well.
///
/// The line is deliberately short: a dozen cards is as many as fit on a
/// screen, and the point of a line is that the thing you copied a moment ago
/// is within reach. This is where everything else waits.
///
/// Cards are kept newest first, capped so a week of copying does not grow
/// without bound, and pictures are kept as paths rather than images: the file
/// is already on disk, and reading it back only when a card comes into view
/// keeps a long history cheap.
///
/// A class rather than a struct because the line holds one of these for the
/// life of the app and every write goes through it.
final class Attic {
    /// How long a card is kept. A choice in the settings, seven to ninety
    /// days, fourteen by default — and the date row on the pill reaches the
    /// whole of it: the fourteen days it draws directly, and one "earlier"
    /// button for the rest when the window is longer than the row.
    ///
    /// This replaced a cap of two hundred cards, which turned out never to
    /// have been read by anything — the history grew without bound while a
    /// constant sat there claiming otherwise. A count is the wrong shape for
    /// this anyway: copying is not regular, so two hundred cards is a day for
    /// someone working through a folder and a month for everyone else, and
    /// neither of them wants the same answer.
    static var retentionDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "retentionDays")
            return [7, 14, 30, 90].contains(stored) ? stored : 14
        }
        set { UserDefaults.standard.set(newValue, forKey: "retentionDays") }
    }

    /// A hard ceiling, high enough never to be reached in ordinary use.
    ///
    /// Not the policy — the retention window is the policy. This is the
    /// guard against a day of bulk copying: a folder dragged in can put
    /// thousands of cards on the line in a minute, and without a ceiling the
    /// whole of it is written to disk and read back on every launch.
    static let hardLimit = 1000

    private(set) var entries: [Entry] = []
    /// Whether a write failed, so the app can say so rather than losing the
    /// history quietly. A clipboard tool that silently forgets is worse than
    /// one that never kept anything.
    private(set) var saveFailed = false
    struct Entry: Codable, Equatable {
        let payload: Payload
        let origin: Origin
        var id: UUID = UUID()
        /// The formatting a text copy arrived with. Absent on every card
        /// stored before it existed, which an optional decodes as nothing —
        /// the old file reads as it always did.
        var rich: RichText?
        /// Whether the user has watched this card. Optional for the same
        /// reason `rich` is: a history written before pins existed decodes
        /// with nothing here, which reads as unpinned.
        var pinned: Bool?
        /// What the QR code in this picture says, when it holds one.
        ///
        /// Three states in one optional, and all three mean something
        /// different:
        ///
        /// - `nil` — never looked at. Every card stored before this existed,
        ///   and every picture from the moment it is hung until the read
        ///   finishes.
        /// - `[]` — looked at, and there is no code in it.
        /// - `["…"]` — looked at, and this is what it says.
        ///
        /// The difference between the first two is the whole reason this is
        /// not a plain array. Without it a picture with no code and a picture
        /// nobody had checked would read the same, and every launch would go
        /// through the whole history again — twenty seconds of work for two
        /// hundred screenshots, to learn what it already knew.
        var qrcodes: [String]?
    }

    /// What a load found, kept apart from what it is done with.
    ///
    /// Two lists rather than one, because the two answers are needed for
    /// different things: the cards go on the line, and the ones being let go
    /// are pictures that have to be put in the Trash rather than left in the
    /// folder for ever.
    struct Loaded {
        var kept: [Entry] = []
        /// Past the retention window, or a picture whose file has gone.
        var letGo: [Entry] = []
    }

    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent("Clothespeg/History.json")
    }

    // MARK: Reading and writing

    /// Everything worth keeping, and everything being let go.
    ///
    /// The two filters are separate questions. A card is out of time when it
    /// is older than the window, and out of reach when the picture it points
    /// at has been deleted from the folder — the second is not a policy, it
    /// is the disk having an opinion, and it applies however new the card is.
    func load() -> Loaded {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return Loaded() }

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays,
                                           to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        var result = Loaded()
        for entry in stored {
            // A pinned card is out of no one's time but its owner's: the
            // retention window stops at the pin. The disk keeps its opinion —
            // a picture whose file is gone has nothing left to show, pinned
            // or not.
            if entry.pinned != true {
                guard entry.origin.at >= cutoff else {
                    result.letGo.append(entry)
                    continue
                }
            }
            if let picture = entry.payload.imageURL,
               !FileManager.default.fileExists(atPath: picture.path) {
                result.letGo.append(entry)
                continue
            }
            result.kept.append(entry)
        }
        // Newest first, counted down to the ceiling. Everything past the
        // ceiling is let go as well, so a bulk copy does not leave the rest
        // of it in the file — except what is pinned, which the ceiling does
        // not spend: a pin that a day of copying could sweep away would not
        // be a pin.
        if result.kept.count > Self.hardLimit {
            var kept: [Entry] = []
            var letGo: [Entry] = []
            var counted = 0
            for entry in result.kept {
                if entry.pinned == true || counted < Self.hardLimit {
                    kept.append(entry)
                    if entry.pinned != true { counted += 1 }
                } else {
                    letGo.append(entry)
                }
            }
            result.kept = kept
            result.letGo.append(contentsOf: letGo)
        }
        return result
    }

    func save(_ entries: [Entry]) {
        self.entries = entries
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            saveFailed = false
        } catch {
            // Kept in memory either way, so the session still works; only the
            // next launch loses it.
            log.error("Could not save the history: \(error.localizedDescription, privacy: .public)")
            saveFailed = true
        }
    }

    /// Whether the history could be read at all.
    ///
    /// Asked before letting anything go, because the difference between "no
    /// cards are old enough to keep" and "the file did not read" is the
    /// difference between clearing up and wiping everything. A load that
    /// failed returns an empty list, and an empty list is indistinguishable
    /// from a history with nothing left in it.
    func historyExists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
