import Foundation

/// Whole export → import in two temporary attics, plus the four category
/// scopes in both directions. Nothing here reads the real Notes.json /
/// History.json, so this runs before a single user card has been handed to
/// a merge rule.
enum TransferProbe {
    static func run() -> String {
        var lines = ["transfer probe:"]
        func check(_ ok: Bool, _ label: String) {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)")
        }

        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("cp-transfer-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        func writeJSON<T: Encodable>(_ list: [T], to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: url, options: .atomic)
        }
        func read<T: Decodable>(_ type: T.Type, at url: URL) -> [T] {
            guard let data = try? Data(contentsOf: url),
                  let list = try? JSONDecoder().decode([T].self, from: data) else { return [] }
            return list
        }

        do {
            let a = TransferStore(root: base.appendingPathComponent("A", isDirectory: true))
            let b = TransferStore(root: base.appendingPathComponent("B", isDirectory: true))
            let c = TransferStore(root: base.appendingPathComponent("C", isDirectory: true))
            let d = TransferStore(root: base.appendingPathComponent("D", isDirectory: true))
            let exports = base.appendingPathComponent("Exports", isDirectory: true)
            let textExports = base.appendingPathComponent("TextExports", isDirectory: true)
            for folder in [a.pictures, a.recordings, b.pictures, b.recordings,
                           c.pictures, c.recordings, d.pictures, d.recordings,
                           exports, textExports] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }

            let full = Set(SyncOption.allCases)
            let shared = UUID()
            let aOnly = UUID()
            let bOnly = UUID()
            let imageID = UUID()
            let textID = UUID()
            let incomingFileID = UUID()
            let localFileID = UUID()
            let newer = Date(timeIntervalSinceNow: -10)
            let older = Date(timeIntervalSinceNow: -3600)
            let voice = Note.Recording(name: "voice.m4a", seconds: 9,
                                       bars: [10, 40, 80, 25])
            let imageName = "shot.png"
            let imageURL = a.pictures.appendingPathComponent(imageName)
            try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageURL)
            try Data([0x00, 0x01]).write(to: a.recordings.appendingPathComponent(voice.name))

            let aNotes: [NoteStore.Entry] = [
                .init(payload: .note(Note(text: "A 版（较新）", recording: voice)),
                      origin: Origin(app: nil, at: newer), id: shared),
                .init(payload: .note(Note(text: "A 独有")),
                      origin: Origin(app: nil, at: newer), id: aOnly),
            ]
            let aHistory: [Attic.Entry] = [
                .init(payload: .image(imageURL), origin: Origin(app: nil, at: newer),
                      id: imageID, pinned: true, qrcodes: [], ocr: "读取到的字"),
                .init(payload: .text("一条纯文字", isCode: false),
                      origin: Origin(app: nil, at: newer), id: textID),
                .init(payload: .file([URL(fileURLWithPath: "/Users/a/Desktop/gone.txt")]),
                      origin: Origin(app: nil, at: newer), id: incomingFileID),
            ]
            try writeJSON(aNotes, to: a.notes)
            try writeJSON(aHistory, to: a.history)

            let bNotes: [NoteStore.Entry] = [
                .init(payload: .note(Note(text: "B 版（较旧）")),
                      origin: Origin(app: nil, at: older), id: shared),
                .init(payload: .note(Note(text: "B 独有")),
                      origin: Origin(app: nil, at: older), id: bOnly),
            ]
            let bHistory: [Attic.Entry] = [
                .init(payload: .file([URL(fileURLWithPath: "/Users/b/Desktop/keep.txt")]),
                      origin: Origin(app: nil, at: older), id: localFileID),
            ]
            try writeJSON(bNotes, to: b.notes)
            try writeJSON(bHistory, to: b.history)

            let (bundle, exported) = try Transfer.export(from: a, into: exports, scope: full)
            check(exported.notes == 2 && exported.history == 2
                  && exported.pictures == 1 && exported.recordings == 1
                  && exported.skippedFiles == 1,
                  "full scope: 2 notes / 2 cards / 1 picture / 1 recording / 1 file card left out")
            check(fm.fileExists(atPath: bundle.appendingPathComponent(Transfer.manifestName).path)
                  && fm.fileExists(atPath: bundle.appendingPathComponent("Pictures/\(imageName)").path)
                  && fm.fileExists(atPath: bundle.appendingPathComponent("Recordings/\(voice.name)").path),
                  "export folder carries manifest and both assets")
            check(Transfer.resolve(exports)?.lastPathComponent == bundle.lastPathComponent,
                  "parent folder resolves to the export inside it")

            let resolved = Transfer.resolve(exports) ?? bundle
            let report = try Transfer.importBundle(resolved, into: b, scope: full)
            check(report.notes == 3, "merge keeps 3 notes, not 2 or 4")
            check(report.history == 3, "merge keeps 3 history cards")
            check(report.skippedFiles == 0, "no Finder-file card reaches the import side")

            let notes = read(NoteStore.Entry.self, at: b.notes)
            let history = read(Attic.Entry.self, at: b.history)
            let sharedNote = notes.first { $0.id == shared }?.payload.note
            check(sharedNote?.text == "A 版（较新）", "same id keeps the newer text")
            check(sharedNote?.recording == voice, "recording metadata survives the merge")
            check(notes.contains { $0.id == aOnly } && notes.contains { $0.id == bOnly },
                  "both Mac-only notes survive")
            check(!history.contains { $0.id == incomingFileID }
                  && history.contains { $0.id == localFileID },
                  "local Finder-file card kept, incoming one skipped")

            // Filtering now re-encodes the JSON on the way out. These three
            // optionals are the fields a hand-written copy would quietly drop.
            let imageEntry = history.first { $0.id == imageID }
            check(imageEntry?.pinned == true && imageEntry?.ocr == "读取到的字"
                  && imageEntry?.qrcodes == [],
                  "optional fields survive the decode/encode round trip")
            let importedImage = imageEntry?.payload.imageURL
            let localImage = b.pictures.appendingPathComponent(imageName)
            check(importedImage?.standardizedFileURL.path == localImage.standardizedFileURL.path
                  && fm.fileExists(atPath: localImage.path),
                  "picture URL re-pointed to this Mac's inbox and file is there")
            check(fm.fileExists(atPath: b.recordings.appendingPathComponent(voice.name).path),
                  "audio file copied, voice-only note stays playable")
            let backups = (try? fm.contentsOfDirectory(atPath: b.root.path))?
                .filter { $0.hasPrefix("Backup-") } ?? []
            check(!backups.isEmpty, "live stores backed up before the import")

            // A missing audio file must not turn a voice-only note into a
            // blank one — the same contract SyncNoteLanding pins down.
            check(!Note(text: "", recording: voice).isBlank,
                  "voice-only note is still a note without its audio file")

            // Export side: one ticked category, nothing else in the bundle.
            let (textBundle, textReport) = try Transfer.export(
                from: a, into: textExports, scope: [.clipboardText])
            check(textReport.notes == 0 && textReport.history == 1
                  && textReport.pictures == 0 && textReport.recordings == 0,
                  "text-only scope exports just the text card")
            check(!fm.fileExists(atPath: textBundle.appendingPathComponent("Pictures").path)
                  && !fm.fileExists(atPath: textBundle.appendingPathComponent("Recordings").path),
                  "text-only bundle carries no asset folders")
            check(read(NoteStore.Entry.self,
                       at: textBundle.appendingPathComponent("Notes.json")).isEmpty,
                  "text-only bundle writes an empty Notes.json")
            let packedCards = read(Attic.Entry.self,
                                   at: textBundle.appendingPathComponent("History.json"))
            check(packedCards.count == 1 && packedCards.first?.id == textID,
                  "text-only bundle keeps only the text card")
            if let data = try? Data(contentsOf: textBundle.appendingPathComponent(Transfer.manifestName)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let scope = object["scope"] as? [String] {
                check(Set(scope) == ["clipboardText"], "manifest records the ticked scope")
            } else {
                check(false, "manifest records the ticked scope")
            }

            // Import side: ticking only notes keeps the metadata but leaves
            // every audio byte and history card behind.
            let cReport = try Transfer.importBundle(resolved, into: c, scope: [.notes])
            let cNotes = read(NoteStore.Entry.self, at: c.notes)
            check(cNotes.count == 2 && read(Attic.Entry.self, at: c.history).isEmpty,
                  "notes-only import brings notes and no history cards")
            check(!fm.fileExists(atPath: c.recordings.appendingPathComponent(voice.name).path),
                  "notes-only import leaves the audio file behind")
            check(cNotes.first { $0.id == shared }?.payload.note?.recording == voice,
                  "recording metadata still travels with the note")
            check(cReport.recordings == 0, "notes-only report shows no audio on this Mac")

            // A bundle cannot give what it never carried, even with every
            // category ticked on the importing Mac.
            let dReport = try Transfer.importBundle(textBundle, into: d, scope: full)
            let dCards = read(Attic.Entry.self, at: d.history)
            check(dCards.count == 1 && dCards.first?.id == textID,
                  "full-scope import of a text-only bundle still imports only text")
            check(read(NoteStore.Entry.self, at: d.notes).isEmpty,
                  "no notes appear from a bundle that carried none")
            check(dReport.notes == 0, "text-only report shows no notes")
        } catch {
            lines.append("FAIL  probe threw: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
