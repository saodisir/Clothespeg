import Foundation

/// One whole attic, named by a single root. The live one is
/// `~/Library/Application Support/Clothespeg/`; the self-test points the
/// same code at a temporary folder so it never touches real notes.
struct TransferStore {
    let root: URL

    var notes: URL { root.appendingPathComponent("Notes.json") }
    var history: URL { root.appendingPathComponent("History.json") }
    var pictures: URL { root.appendingPathComponent("Pictures", isDirectory: true) }
    var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }

    static var live: TransferStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return TransferStore(root: base.appendingPathComponent("Clothespeg", isDirectory: true))
    }
}

struct TransferReport {
    var notes = 0
    var history = 0
    var pictures = 0
    var recordings = 0
    /// Finder-file cards that took no part in this transfer. They are path
    /// references into somebody else's disk; on another Mac they are dead
    /// cards, so they are neither packed nor imported.
    var skippedFiles = 0
}

enum TransferError: LocalizedError {
    case badBundle
    case unreadable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .badBundle: return "Not a Clothespeg export folder (manifest missing or newer version)."
        case .unreadable(let what): return "Could not read \(what)."
        case .writeFailed(let what): return "Could not write \(what)."
        }
    }
}

/// Manual export / import. The four content categories in `SyncOption` are
/// one scope shared by both buttons: what you tick is what goes out, and
/// what comes back in.
///
/// ⚠️ Filtering by category means the JSON has to be decoded and re-encoded
/// on the way out. That is a change from the earlier byte-for-byte copy, and
/// the reason for that copy was the hand-written Codable on `Note`. Both
/// sides still use the system encoder/decoder with **no hand-copied field
/// list** (the import side has always re-encoded), so a field cannot vanish
/// here on its own. The rule that still matters: adding a field to `Note`
/// must update CodingKeys / init(from:) / encode(to:) together.
enum Transfer {
    static let manifestName = "manifest.json"
    static let version = 1
    static let folderPrefix = "Clothespeg-导出-"

    private struct Manifest: Codable {
        var version: Int
        var exportedAt: Date
        var notes: Int
        var history: Int
        var pictures: Int
        var recordings: Int
        /// Which categories this bundle actually contains. Optional so a
        /// bundle written before scopes existed still opens as a full one.
        var scope: [String]?
    }

    private static let fm = FileManager.default

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func count(in folder: URL) -> Int {
        (try? fm.contentsOfDirectory(atPath: folder.path))?.count ?? 0
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return list
    }

    private static func write<T: Encodable>(_ list: [T], to url: URL) throws {
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(list)
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw TransferError.writeFailed(url.lastPathComponent)
        }
    }

    /// Two lists of the same shape, one id each. A newer `origin.at` wins;
    /// an id that only one side has is kept. Newest first, the order both
    /// stores already use.
    static func merged<T>(_ local: [T], _ incoming: [T],
                          id: (T) -> UUID, at: (T) -> Date) -> [T] {
        var byID: [UUID: T] = [:]
        var dates: [UUID: Date] = [:]
        for item in local {
            let key = id(item)
            byID[key] = item
            dates[key] = at(item)
        }
        for item in incoming {
            let key = id(item)
            if let existing = dates[key], existing >= at(item) { continue }
            byID[key] = item
            dates[key] = at(item)
        }
        return byID.values.sorted { at($0) > at($1) }
    }

    /// A payload as it should look on this Mac. Pictures the export carried
    /// are copied into the local inbox and re-pointed at it; Finder-file
    /// cards are dropped. Everything else is already portable.
    ///
    /// ⚠️ A picture that lives outside the inbox (a screenshot on the
    /// Desktop) is left with its original URL. The attic's own load already
    /// lets a card go when its file is gone, so no dead card is invented by
    /// the import.
    private static func portable(_ payload: Payload, bundle: URL,
                                 store: TransferStore) -> Payload? {
        switch payload {
        case .file: return nil
        case .image(let url):
            let name = url.lastPathComponent
            let packed = bundle.appendingPathComponent("Pictures/\(name)")
            guard fm.fileExists(atPath: packed.path) else { return payload }
            let local = store.pictures.appendingPathComponent(name)
            if !fm.fileExists(atPath: local.path) {
                try? fm.createDirectory(at: store.pictures,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
                try? fm.copyItem(at: packed, to: local)
            }
            return .image(local)
        case .text, .note: return payload
        }
    }

    /// The export folder itself, or its only child that carries a manifest.
    /// Lets a hand pick the parent folder by accident without failing.
    static func resolve(_ chosen: URL) -> URL? {
        if fm.fileExists(atPath: chosen.appendingPathComponent(manifestName).path) {
            return chosen
        }
        let children = (try? fm.contentsOfDirectory(
            at: chosen, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return children
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(manifestName).path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .last
    }

    private static func packedScope(_ manifest: Manifest) -> Set<SyncOption> {
        manifest.scope.map { Set($0.compactMap(SyncOption.init(rawValue:))) }
            ?? Set(SyncOption.allCases)
    }

    /// Pack only the ticked categories into a dated folder. Pictures and
    /// Recordings travel as whole folders, but only when their category is
    /// in scope; an audio file without its note would be an orphan.
    static func export(from store: TransferStore, into parent: URL,
                       scope: Set<SyncOption> = Set(SyncOption.allCases))
        throws -> (URL, TransferReport) {
        let bundle = parent.appendingPathComponent(folderPrefix + stamp(), isDirectory: true)
        do {
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw TransferError.writeFailed(bundle.lastPathComponent)
        }

        let notes = decode(NoteStore.Entry.self, at: store.notes)
        let history = decode(Attic.Entry.self, at: store.history)
        let packedNotes = SyncRules.allows(.note, in: scope) ? notes : []
        let packedHistory = history.filter { SyncRules.allows($0.payload, in: scope) }
        let wantsPictures = SyncRules.allows(.image, in: scope)
        let wantsAudio = SyncNoteLanding.carriesAudio(in: scope)

        var report = TransferReport()
        report.notes = packedNotes.count
        report.history = packedHistory.count
        report.pictures = wantsPictures ? count(in: store.pictures) : 0
        report.recordings = wantsAudio ? count(in: store.recordings) : 0
        report.skippedFiles = history.filter { SyncChannel($0.payload) == .file }.count

        try write(packedNotes, to: bundle.appendingPathComponent("Notes.json"))
        try write(packedHistory, to: bundle.appendingPathComponent("History.json"))

        for (source, name, wanted) in [(store.pictures, "Pictures", wantsPictures),
                                       (store.recordings, "Recordings", wantsAudio)] {
            guard wanted, fm.fileExists(atPath: source.path) else { continue }
            do {
                try fm.copyItem(at: source, to: bundle.appendingPathComponent(name))
            } catch {
                throw TransferError.writeFailed(name)
            }
        }

        let manifest = Manifest(version: version, exportedAt: Date(),
                                notes: report.notes, history: report.history,
                                pictures: report.pictures, recordings: report.recordings,
                                scope: scope.map(\.rawValue).sorted())
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: bundle.appendingPathComponent(manifestName), options: .atomic)
        } catch {
            throw TransferError.writeFailed(manifestName)
        }
        return (bundle, report)
    }

    /// Merge an export into this Mac. Never replaces either store wholesale:
    /// anything written here after the export was made has to survive.
    /// A category has to be ticked here **and** present in the bundle; the
    /// intersection is what actually moves.
    static func importBundle(_ bundle: URL, into store: TransferStore,
                             scope: Set<SyncOption> = Set(SyncOption.allCases))
        throws -> TransferReport {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == version else {
            throw TransferError.badBundle
        }
        let effective = scope.intersection(packedScope(manifest))

        // Rollback point before a single byte of the live stores is touched.
        let backup = store.root.appendingPathComponent("Backup-" + stamp(), isDirectory: true)
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        for file in [store.notes, store.history] where fm.fileExists(atPath: file.path) {
            try? fm.copyItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent))
        }

        let incomingNotes = SyncRules.allows(.note, in: effective)
            ? decode(NoteStore.Entry.self, at: bundle.appendingPathComponent("Notes.json"))
            : [NoteStore.Entry]()
        let incomingHistory = decode(Attic.Entry.self,
                                     at: bundle.appendingPathComponent("History.json"))
            .filter { SyncRules.allows($0.payload, in: effective) }

        var skipped = 0
        let portableNotes: [NoteStore.Entry] = incomingNotes.compactMap { entry in
            guard let payload = portable(entry.payload, bundle: bundle, store: store) else {
                skipped += 1
                return nil
            }
            return NoteStore.Entry(payload: payload, origin: entry.origin, id: entry.id)
        }
        let portableHistory: [Attic.Entry] = incomingHistory.compactMap { entry in
            guard let payload = portable(entry.payload, bundle: bundle, store: store) else {
                skipped += 1
                return nil
            }
            // Every optional field rides along. A hand-written copy that
            // forgot `pinned` or `ocr` would quietly unpin cards on import.
            return Attic.Entry(payload: payload, origin: entry.origin, id: entry.id,
                               rich: entry.rich, pinned: entry.pinned,
                               qrcodes: entry.qrcodes, ocr: entry.ocr)
        }

        let localNotes = decode(NoteStore.Entry.self, at: store.notes)
        let localHistory = decode(Attic.Entry.self, at: store.history)
        let notes = merged(localNotes, portableNotes,
                           id: { $0.id }, at: { $0.origin.at })
        let history = merged(localHistory, portableHistory,
                             id: { $0.id }, at: { $0.origin.at })

        // Recordings are named by UUID, so an existing file is already the
        // same voice. The note keeps its `recording` metadata either way —
        // see SyncNoteLanding: a missing file means "not playable yet", not
        // "this note lost its voice".
        if SyncNoteLanding.carriesAudio(in: effective) {
            let packedRecordings = bundle.appendingPathComponent("Recordings", isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: packedRecordings.path)) ?? [] {
                let from = packedRecordings.appendingPathComponent(name)
                let to = store.recordings.appendingPathComponent(name)
                guard !fm.fileExists(atPath: to.path) else { continue }
                try? fm.createDirectory(at: store.recordings,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
                try? fm.copyItem(at: from, to: to)
            }
        }

        try write(notes, to: store.notes)
        try write(history, to: store.history)

        var report = TransferReport()
        report.notes = notes.count
        report.history = history.count
        report.pictures = count(in: store.pictures)
        report.recordings = count(in: store.recordings)
        report.skippedFiles = skipped
        return report
    }
}
