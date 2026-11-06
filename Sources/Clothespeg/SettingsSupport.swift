import AppKit
import ApplicationServices
import AVFAudio
import UserNotifications

/// The licence, in full, as it has to be shown.
///
/// Reproduction is not a courtesy here, it is the condition. The licence
/// permits this code to be used, changed and redistributed for noncommercial
/// purposes — and asks for one thing in return: that the copyright notice and
/// the Required Notice line travel with every copy. A build without this text
/// is not a build that skipped a formality, it is a build that is not licensed
/// at all.
///
/// Selling the software, or any other commercial use, is *not* granted by this
/// licence. The Provenance below says where such a grant does come from: buying
/// the Mac App Store edition, under the App Store's standard terms. Everything
/// else commercial still needs a separate licence from the licensor.
///
/// The last part is easy to miss and is not optional either. It is where the
/// author says what the licence does *not* cover: the Tendedero name and the
/// icon drawn by `scripts/make-icon.swift`, and the Clothespeg name and icon.
/// A modified version has to carry a different name and a different icon, and
/// this notice is how its readers are told so.
///
/// Kept in step with the LICENSE file at the root of the project. If that
/// file changes, this has to change with it.
enum LicenceText {
    static let full = """

    Required Notice: Copyright 2026 VIZWISE (HONGKONG) LIMITED

    PolyForm Noncommercial License 1.0.0

    Acceptance

    In order to get any license under these terms, you must agree to them as both strict obligations and conditions to all your licenses.

    Copyright License

    The licensor grants you a copyright license for the software to do everything you might do with the software that would otherwise infringe the licensor's copyright in it for any permitted purpose. However, you may only distribute the software according to Distribution License and make changes or new works based on the software according to Changes and New Works License.

    Distribution License

    The licensor grants you an additional copyright license to distribute copies of the software. Your license to distribute covers distributing the software with changes and new works permitted by Changes and New Works License.

    Notices

    You must ensure that anyone who gets a copy of any part of the software from you also gets a copy of these terms or the URL for them above, as well as copies of any plain-text lines beginning with `Required Notice:` that the licensor provided with the software. For example:

    Required Notice: Copyright Yoyodyne, Inc. (http://example.com)

    Changes and New Works License

    The licensor grants you an additional copyright license to make changes and new works based on the software for any permitted purpose.

    Patent License

    The licensor grants you a patent license for the software that covers patent claims the licensor can license, or becomes able to license, that you would infringe by using the software.

    Noncommercial Purposes

    Any noncommercial purpose is a permitted purpose.

    Personal Uses

    Personal use for research, experiment, and testing for the benefit of public knowledge, personal study, private entertainment, hobby projects, amateur pursuits, or religious observance, without any anticipated commercial application, is use for a permitted purpose.

    Noncommercial Organizations

    Use by any charitable organization, educational institution, public research organization, public safety or health organization, environmental protection organization, or government institution is use for a permitted purpose regardless of the source of funding or obligations resulting from the funding.

    Fair Use

    You may have "fair use" rights for the software under the law. These terms do not limit them.

    No Other Rights

    These terms do not allow you to sublicense or transfer any of your licenses to anyone else, or prevent the licensor from granting licenses to anyone else. These terms do not imply any other licenses.

    Patent Defense

    If you make any written claim that the software infringes or contributes to infringement of any patent, your patent license for the software granted under these terms ends immediately. If your company makes such a claim, your patent license ends immediately for work on behalf of your company.

    Violations

    The first time you are notified in writing that you have violated any of these terms, or done anything with the software not covered by your licenses, your licenses can nonetheless continue if you come into full compliance with these terms, and take practical steps to correct past violations, within 32 days of receiving notice. Otherwise, all your licenses end immediately.

    No Liability

    As far as the law allows, the software comes as is, without any warranty or condition, and the licensor will not be liable to you for any damages arising out of these terms or the use or nature of the software, under any kind of legal claim.

    Definitions

    The licensor is the individual or entity offering these terms, and the software is the software the licensor makes available under these terms. You refers to the individual or entity agreeing to these terms. Your company is any legal entity, sole proprietorship, or other kind of organization that you work for, plus all organizations that have control over, are under the control of, or are under common control with that organization. Control means ownership of substantially all the assets of an entity, or the power to direct its management and policies by vote, contract, or otherwise. Control can be direct or indirect. Your licenses are all the licenses granted to you for the software under these terms. Use means anything you do with the software requiring one of your licenses.

    ---

    Provenance

    This project is based on Tendedero by Alejandro Bujan's work and is used here
    under the MIT License. Its rope, the clothespin, the glass and the swing of
    a card landing on the line remain MIT and are unchanged by this fork.

    The additions written for Clothespeg - the data model, the notes rope, the
    pill, watching and hiding, the screenshot inbox, paging and everything on
    top of Tendedero - are, from version 2.0.0 onward, under the PolyForm
    Noncommercial License 1.0.0 above. NOTICE records the boundary with earlier
    releases.

    The licensor for the Clothespeg additions is VIZWISE (HONGKONG) LIMITED,
    which is also the company a release is signed with.

    Selling Clothespeg, or any other commercial use, is not granted by this
    licence. A copy built from the source repository is for noncommercial use
    only, as the licence above defines it.

    Commercial use at work is available through the Mac App Store edition:
    buying that edition grants the purchaser the right to use Clothespeg for
    commercial purposes, licensed by VIZWISE (HONGKONG) LIMITED under the
    App Store's standard licence terms.

    Reselling, embedding in a commercial product, or redistributing the source
    for a commercial purpose is not covered by that purchase and still needs a
    separate commercial licence from VIZWISE (HONGKONG) LIMITED.

    ---

    Name and icon

    This licence covers the source code only. It does not grant any rights to the
    Tendedero name or the Tendedero icon, including the icon artwork drawn by
    scripts/make-icon.swift and the images in the docs folder - nor to the
    Clothespeg name or icon. Modified or redistributed versions must use a different
    name and a different icon, and must not suggest that they are Tendedero,
    Clothespeg, or endorsed by either author.
"""
}

/// Whether this app may press keys in other apps, and how to ask for it.
///
/// One permission, for one thing. Clicking a card puts the payload on the
/// pasteboard and then has to press ⌘V in whatever app the user came from;
/// pressing a key in another app is exactly what Accessibility governs, and
/// without it the press is dropped without an error — the card copy still
/// works and the paste simply does not happen, which is the kind of failure
/// that reads as a bug in the app rather than as a permission.
///
/// So the app asks for nothing else, and it says here what the one thing is.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Straight to the pane, rather than to the top of System Settings with
    /// the user left to find it. The list is long and this is one row of it.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// The answers that live in more than one place.
///
/// Three of them are reachable from the menu bar and from the settings window at
/// the same time — the screenshot inbox, "peek at new cards" and "copy with
/// formatting" — and all three are stored as a plain `UserDefaults` answer that
/// either place can write. UserDefaults notifies nobody in its own process, and
/// the settings window is kept alive after it closes rather than rebuilt — so a
/// page that read the answer once would go on showing it for ever, while the
/// menu went on showing the truth. That is exactly the report from 2026-11-02:
/// the same switch said two things in two places.
///
/// So each setter is the one place its answer changes, and it says so. One name
/// for all of them rather than one each: a page re-reads its own three or four
/// booleans for nothing, and a name per answer is a table to keep in step — the
/// table being the very thing that went out of date. The `object` is the
/// `UserDefaults` key, which costs nothing and makes the log readable.
extension Notification.Name {
    static let settingsAnswerChanged = Notification.Name("app.clothespeg.settingsAnswerChanged")
}

enum SettingsAnswers {
    /// Says that one answer moved. Same-value writes never reach here: every
    /// setter guards against them first, which is what stops a page that is
    /// echoing a value it was just told about from starting a loop.
    static func announce(_ key: String) {
        NotificationCenter.default.post(name: .settingsAnswerChanged, object: key)
    }
}

/// Whether this app may look at the screen, and how to ask for it.
///
/// The third permission, and the only one that guards a feature rather than a
/// convenience: without it the capture shortcut does nothing at all, where
/// Accessibility merely turns a double-click's paste into a plain copy and
/// Notifications merely stops the banner. A refusal here is a feature that is
/// not there, which is why the row says so instead of leaving a green tick to
/// be guessed at.
///
/// `hasAsked` exists because the two silences are not the same silence. macOS
/// shows its own prompt once; after a refusal it will not show it again from
/// inside the app, and calling the request again just returns "no" without
/// asking. The row has to know which of the two it is looking at to offer the
/// right button — ask, or go to System Settings.
enum ScreenRecordingPermission {
    /// Whether permission is already in place. Read rather than requested, so
    /// it can be asked every second by the page without a prompt.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static let askedKey = "askedForScreenRecording"

    /// Whether this app has ever put the question to macOS.
    static var hasAsked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    /// Puts the question, once.
    ///
    /// False does not mean "refused": the case that matters most here is a
    /// grant that has been recorded but not yet taken effect, because the
    /// running process is the one that was already told no. The window server
    /// only hears the new answer after a restart, which the row says out loud.
    @discardableResult
    static func request() -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        return CGRequestScreenCaptureAccess()
    }

    /// Straight to the screen recording pane, rather than the top of System
    /// Settings with the user left to find the right list.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

/// Whether this app may draw a banner for a reminder, and how to ask for it.
///
/// The banner is the system's own; the bell and the rope coming down are the
/// app's own and work without this. So a refusal is not a broken reminder —
/// it is one that does not reach past the app's window, which the settings
/// row says out loud rather than hiding behind a green tick.
enum NotificationPermission {
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks the system once. After a refusal macOS will not ask again from
    /// inside the app, so the row offers the settings pane instead.
    @discardableResult
    static func request() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Straight to the notifications pane, with this app's row selected
    /// where the system honours it.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        NSWorkspace.shared.open(url)
    }
}

/// Whether this app may hear the microphone, and how to ask for it.
///
/// The recording panel asks when a voice is first made, but macOS shows its
/// own prompt only once. After a refusal the request answers "no" without
/// putting anything on screen, so the settings page is the other door: it
/// says which of the three states the line is in and offers the one action
/// that still works — ask, or go to System Settings.
///
/// `AVAudioApplication` is the macOS 14 door for a recorder. Asking
/// `AVCaptureDevice` instead belongs to the capture-session world and can
/// leave a recorder with no prompt at all, which is exactly the silence
/// this row was written to answer.
enum MicrophonePermission {
    enum State: String {
        case undetermined, denied, granted
    }

    /// Read rather than requested, so the page can ask it every second
    /// without ever putting a prompt up on its own.
    static var state: State {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    static var isGranted: Bool { state == .granted }

    private static let askedKey = "askedForMicrophone"

    /// Whether this app has ever put the question to macOS, either from the
    /// recording panel or from the settings page.
    static var hasAsked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    /// Puts the question, once. The answer is read back rather than trusted:
    /// a grant recorded while this process was running may need a restart
    /// before the recorder can hear it.
    @discardableResult
    static func request() async -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        // A background app has no window of its own in front, and a TCC
        // prompt with nowhere to land is a prompt nobody sees.
        NSApp.activate(ignoringOtherApps: true)
        let before = state
        let started = Date()
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        // An immediate callback means macOS already had an answer and never
        // put a dialog up; a slow one means the user was actually asked. Those
        // two failures need different fixes, so the log says which happened.
        let waited = Date().timeIntervalSince(started)
        diagLog("Microphone permission: \(before.rawValue) -> asked, granted=\(granted), "
                + "state=\(state.rawValue), waited=\(String(format: "%.2f", waited))s")
        return granted
    }

    /// Straight to the microphone pane rather than the top of System
    /// Settings, the same as the other two permissions.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}

/// What is being kept, counted.
struct StorageStats {
    var cards: Int
    var pictures: Int
    var bytes: Int64

    var size: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// Counted from the two places the app writes: the history file for
    /// cards, the pictures folder for pictures.
    ///
    /// The card count is the length of the stored list rather than the number
    /// on the line — the line shows what fits on screen, and a number that
    /// small would answer a question nobody asked.
    static func measure() -> StorageStats {
        var stats = StorageStats(cards: 0, pictures: 0, bytes: 0)

        let attic = Attic()
        stats.cards = attic.load().kept.count

        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: Inbox.folder,
                                                      includingPropertiesForKeys: [.fileSizeKey]) {
            for file in contents where !file.hasDirectoryPath {
                stats.pictures += 1
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                stats.bytes += Int64(size)
            }
        }
        return stats
    }
}

/// Sweeping, asked for by hand rather than waited for.
///
/// The clearing runs at launch, which is the right time for it — but not the
/// only time someone might want it, and a settings page that shows a number
/// and offers no way to change it is a page that only reports. This is the
/// same work `Line.restore` does, reached from the window.
enum LineKeeper {
    /// The line this app is showing. One of them, set once at launch, so the
    /// settings window can reach it without being handed it through four
    /// layers of view.
    @MainActor static weak var line: Line?

    /// Brings the watched-folder watchers in line with the store. Set once at
    /// launch, for the same reason `line` is: the settings page that adds and
    /// removes folders has to reach the app delegate without being threaded
    /// through the view tree.
    @MainActor static var folderWatchSync: (() -> Void)?

    /// Both sides on the main actor, because the line is: it is the app's
    /// state and everything that reads it runs on the main thread. The
    /// settings window is main-actor too, so this costs nothing and says
    /// plainly which thread the answer has to come from.
    @MainActor
    static func sweepNow() {
        line?.sweepNow()
    }
}
