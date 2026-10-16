import Foundation

/// Where copied pictures are kept, and — when the user asks for it — where
/// screenshots land.
///
/// Tendedero turned this into an inbox uninvited: it took over the macOS
/// screenshot settings the moment it ran. Clothespeg hangs copies only, and
/// for a long time that was the whole story — you press the same shortcut you
/// always press, and a picture arrives here only because you copied it.
///
/// The takeover is back, as an opt-in called the screenshot inbox: the menu's
/// "Hang new screenshots" points macOS at this folder, so a capture hangs the
/// way a copy does, and the previous settings are saved first and put back
/// when the switch goes off or the app quits. Off, macOS is never touched —
/// the promise stands for everyone who never opens that switch.
///
/// Copies can be private, so the folder is created with permissions only its
/// owner can enter, and the files written into it keep the same rule.
enum Inbox {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clothespeg/Pictures", isDirectory: true)
    }()

    /// Creates the folder with owner-only access, if it is not there yet.
    @discardableResult
    static func prepare() -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                log.error("Could not create the pictures folder: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return true
    }

    /// Whether a file lives in this folder. Those are discarded to the Trash,
    /// or the folder would fill up with forgotten copies. A picture that came
    /// from somewhere else — a screenshot saved to the Desktop, a photo
    /// dragged out of Preview — stays where it is.
    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// Takes a picture in from a watched folder, as a copy this app owns.
    ///
    /// A watched folder is somebody else's ground, and a card that hangs by
    /// reference to it lives only as long as the watch does. A copy is the
    /// answer the clipboard already gives — every copied picture keeps its
    /// own copy here — so a picture a watched folder hands over follows the
    /// same road: the original stays where it was, the card owns its copy,
    /// and discarding the card trashes the copy and nothing else.
    ///
    /// Answers nil when the copy could not be made — a file that vanished
    /// between the listing and the read, most often.
    static func copyImage(from url: URL) -> URL? {
        prepare()
        let target = uniqueURL(for: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            log.error("Could not take in \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A name for the copy that collides with nothing already in the folder:
    /// the first free `name`, `name 2`, `name 3`…
    private static func uniqueURL(for name: String) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(
                ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }


    /// Whether macOS stamped this file as a screen capture. The stamp goes on
    /// every capture the system writes wherever it saves them, so a file in
    /// this folder carrying it is a capture, whoever asked for it.
    static func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }

    /// Puts every picture no card is pointing at into the Trash.
    ///
    /// The folder is filled as copies are made, and emptied as cards are let
    /// go, so in ordinary use it drains itself. What it cannot do is drain
    /// the gap between writing a picture and writing the history that names
    /// it: a crash, a force quit, a battery going flat in that window leaves
    /// a file that nothing will ever look for and nothing will ever clean up.
    /// Left alone that is a folder that grows by a few megabytes a month for
    /// no reason anyone can see from the outside.
    ///
    /// `keeping` is every picture the history still names, as paths. Called
    /// only once the history has been read — an unreadable file would hand
    /// this an empty set, and an empty set here means every picture goes.
    static func sweep(keeping paths: Set<URL>) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder,
                                                         includingPropertiesForKeys: nil)
        else { return }
        let named = Set(paths.map { $0.standardizedFileURL.path })
        var swept = 0
        for file in contents where !file.hasDirectoryPath {
            guard !named.contains(file.standardizedFileURL.path) else { continue }
            // Only the files this app writes: its own copies, and — with the
            // screenshot inbox on — captures macOS saved here. Anything else
            // in the folder is not the app's to move, however it got there.
            let ours = file.lastPathComponent.hasPrefix("Clipboard ") || isScreenCapture(file)
            guard ours else { continue }
            // A capture written in the last minute may be on its way to the
            // line — the watcher is slower than a sweep that happens to run
            // beside it — so a fresh one is left for the next sweep to judge.
            if isScreenCapture(file),
               let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
               Date().timeIntervalSince(created) < 60 { continue }
            do {
                try fm.trashItem(at: file, resultingItemURL: nil)
                swept += 1
            } catch {
                log.error("Could not sweep \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if swept > 0 {
            log.notice("Swept \(swept) unclaimed picture(s) from the folder")
        }
    }

    // MARK: Screenshot inbox

    // Tendedero's takeover, asked for first. The values macOS holds are saved
    // before the first one is written, and put back when the switch goes off
    // or the app quits — so macOS is never left saving into a folder nobody
    // is watching.

    private static let captureDomain = "com.apple.screencapture" as CFString
    /// macOS 26 and earlier read "location". macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    /// macOS 27 keeps screen recordings apart, in "location-screenrecording".
    /// Earlier versions send them wherever "location" points.
    private static let recordingLocationKey = "location-screenrecording" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    /// Whether a capture is saved as a file or sent to the clipboard, Preview
    /// and so on. macOS 26 and earlier read "target"; macOS 27 has one for
    /// screenshots and one for recordings.
    private static let targetKey = "target" as CFString
    private static let screenshotTargetKey = "target-screenshot" as CFString
    private static let recordingTargetKey = "target-screenrecording" as CFString

    private static let enabledKey = "screenshotInboxEnabled"
    private static let savedKey = "screenshotInboxSavedSettings"

    /// The user's choice, kept across launches. Off unless asked for.
    static var screenshotInboxEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether macOS is currently sending captures to this folder.
    ///
    /// Both keys are read because they disagree about who is being asked:
    /// macOS 26 and earlier carry "location" alone, macOS 27 carries
    /// "location-screenshot" beside it, and it is the screenshot one that
    /// ⌘⇧5's own menu writes. Whichever exists is the one that answers.
    static var isApplied: Bool {
        func pointsHere(_ key: CFString) -> Bool? {
            guard let current = CFPreferencesCopyAppValue(key, captureDomain) as? String else { return nil }
            return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
                == folder.standardizedFileURL
        }
        if let screenshot = pointsHere(screenshotLocationKey) { return screenshot }
        return pointsHere(locationKey) ?? false
    }

    /// Whether the save location has moved away from this folder — the
    /// user's own doing, from ⌘⇧5's menu. Asked with a synchronize first,
    /// so the answer comes from cfprefsd rather than from this process's
    /// cached copy of it, which would not know what the user just did.
    static func locationMovedAway() -> Bool {
        CFPreferencesAppSynchronize(captureDomain)
        return !isApplied
    }

    /// Points macOS at this folder, keeping whatever it held first. Called
    /// again after a crash left the settings applied re-saves nothing: the
    /// guard on `isApplied` keeps our own values from becoming the "previous"
    /// ones.
    static func apply() {
        prepare()
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if !isApplied {
            saved = [:]
            saved["location"] = CFPreferencesCopyAppValue(locationKey, captureDomain) as? String
            saved["locationScreenshot"] = CFPreferencesCopyAppValue(screenshotLocationKey, captureDomain) as? String
            saved["thumbnail"] = CFPreferencesCopyAppValue(thumbnailKey, captureDomain) as? Bool
        }
        // Recordings and the target came later: settings saved by an earlier
        // version lack them, and the value macOS has now is still the user's own.
        if saved["recordingSaved"] == nil {
            saved["locationRecording"] = CFPreferencesCopyAppValue(recordingLocationKey, captureDomain) as? String
            saved["recordingSaved"] = true
        }
        if saved["targetSaved"] == nil {
            saved["target"] = CFPreferencesCopyAppValue(targetKey, captureDomain) as? String
            saved["targetScreenshot"] = CFPreferencesCopyAppValue(screenshotTargetKey, captureDomain) as? String
            saved["targetRecording"] = CFPreferencesCopyAppValue(recordingTargetKey, captureDomain) as? String
            saved["targetSaved"] = true
        }
        UserDefaults.standard.set(saved, forKey: savedKey)
        // Files, not the clipboard: saving to the clipboard would leave
        // nothing in the folder to hang, and taking a card off the line puts
        // it back on the pasteboard anyway. The floating thumbnail goes too,
        // so the file is written at once instead of five seconds later.
        setPref(locationKey, folder.path)
        setPref(screenshotLocationKey, folder.path)
        setPref(recordingLocationKey, folder.path)
        setPref(targetKey, "file")
        setPref(screenshotTargetKey, "file")
        setPref(recordingTargetKey, "file")
        setPref(thumbnailKey, false)
    }

    /// Puts back whatever macOS saved where before the takeover. A no-op when
    /// the settings are not ours to restore.
    static func restore() {
        guard isApplied else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        setPref(locationKey, saved["location"])
        setPref(screenshotLocationKey, saved["locationScreenshot"])
        setPref(recordingLocationKey, saved["locationRecording"])
        setPref(targetKey, saved["target"])
        setPref(screenshotTargetKey, saved["targetScreenshot"])
        setPref(recordingTargetKey, saved["targetRecording"])
        setPref(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func setPref(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, captureDomain)
        CFPreferencesAppSynchronize(captureDomain)
    }
}