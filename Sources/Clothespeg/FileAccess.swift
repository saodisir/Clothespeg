import AppKit
import Foundation

/// Whether this app may actually open the files it is holding a card of.
///
/// A card of files is a reference, not a copy: it keeps the paths the copy
/// carried and hands them back out when the card is dragged. Nothing in
/// that path ever opens the file — the name, the icon and the size are all
/// things the system will tell you about a file you cannot read.
///
/// That is fine until the file lives in a folder the system guards, which
/// on a modern macOS is `~/Downloads`, `~/Desktop` and `~/Documents`. A
/// file in one of those is not readable by an app that has never been
/// granted the folder, and the grant is only ever prompted for by an
/// actual read. So a card of three files copied out of `~/Downloads` is a
/// card this app can describe and cannot hand over: the drag starts, the
/// pasteboard is right, and the Finder refuses the drop and gives the card
/// back (measured 2026-11-07 — see `fileWriters` in GrabArea.swift).
///
/// Opening one file when the card is made is what asks the question, once
/// per folder, at the moment the app first takes charge of somebody else's
/// file. It changes nothing when the file is readable already, and it is
/// the same read the picture path was already doing in order to make its
/// thumbnail — which is why a card of one picture from the same folder has
/// always dragged out while a card of three never did.
enum FileAccess {
    /// Whether this app can open the file right now — and, the first time
    /// it is asked about a guarded folder, the question itself.
    ///
    /// A folder is opened rather than read: what the system guards is the
    /// opening, and enumerating somebody's Downloads to find that out would
    /// be a read the app has no use for.
    static func canOpen(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
            guard descriptor >= 0 else { return false }
            close(descriptor)
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    /// Asks the system for access to these files, by opening them.
    ///
    /// Deliberately silent: a folder the user has refused stays refused,
    /// and the card is still a card — it can be previewed, opened and
    /// pasted as text. Only the drag out of it stays broken, and saying so
    /// is `Line.explainBlockedDrag`'s job, at the moment somebody tries.
    static func claim(_ urls: [URL]) {
        for url in urls { _ = canOpen(url) }
    }

    /// The first of these files this app cannot open, if any.
    ///
    /// The drag asks this before it starts: a card it cannot hand over is a
    /// drag the Finder will refuse, and the refusal comes back with nothing
    /// said. Better to say it here, once, where there is a button next to it.
    static func firstBlocked(in urls: [URL]) -> URL? {
        urls.first { !canOpen($0) }
    }

    /// The folder a blocked file lives in, as the user knows it: the last
    /// component of its parent, which is `Downloads` for both
    /// `~/Downloads/x.png` and anything further inside.
    static func folderName(of url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }

    /// Opens the pane that can actually fix this.
    ///
    /// A refused folder is refused for good as far as this app is concerned:
    /// the system asks once, and never again once the answer is no. The
    /// switch lives in System Settings → Privacy & Security → Files and
    /// Folders, and this is the deep link straight to it.
    static func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        guard let url = URL(string: pane) else { return }
        NSWorkspace.shared.open(url)
    }
}
