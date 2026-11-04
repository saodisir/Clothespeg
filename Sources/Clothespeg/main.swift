import AppKit

// One-time carry-over of the saved settings onto the app's new identity.
//
// macOS 26 decides whether an app may paint a menu-bar item with a per-app
// authorization keyed by bundle id, and the one held for
// com.vizwise.clothespeg went bad: AppKit built a valid, visible status item
// and the WindowServer still refused to commit it, so the icon never showed —
// whatever the build. A fresh bundle id starts with a clean authorization (the
// same fix Flyring shipped for the same symptom), so the app now lives at
// com.vizwise.clothespeg.app.
//
// Settings are stored under the bundle id, so they have to be moved across
// once — and before anything reads them: Line reads its deck the moment
// AppDelegate is built, so this runs first, not in didFinishLaunching.
private func migrateSettingsToNewIdentity() {
    let newID = "com.vizwise.clothespeg.app"
    let oldID = "com.vizwise.clothespeg"
    guard Bundle.main.bundleIdentifier == newID else { return }

    let defaults = UserDefaults.standard
    let marker = "migratedFromBundleID"
    guard !defaults.bool(forKey: marker) else { return }

    let old = defaults.persistentDomain(forName: oldID) ?? [:]
    for (key, value) in old where key != marker {
        defaults.set(value, forKey: key)
    }
    defaults.set(true, forKey: marker)
    defaults.synchronize()
}

MainActor.assumeIsolated {
    migrateSettingsToNewIdentity()
    // Layout harness: render one editor window to a PNG and quit. Point
    // `CLOTHESPEG_EDITOR_PREVIEW` at a picture and `CLOTHESPEG_EDITOR_SHOT` at
    // where the PNG should go. Nothing in ordinary use sets either.
    if let picture = ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW"] {
        let shot = ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_SHOT"] ?? "/tmp/editor-preview.png"
        let width = Double(ProcessInfo.processInfo.environment["CLOTHESPEG_EDITOR_PREVIEW_WIDTH"] ?? "") ?? 980
        EditorPreview.render(picture: picture, to: shot, size: NSSize(width: width, height: 700))
        exit(0)
    }
    // Layout harness: render the settings window to a PNG and quit. The page is
    // SwiftUI, so nothing else in this repo can look at it — and the one failure
    // it has is silent: a row added to a page pushes the last one past the
    // bottom edge, where it is still there and still unreachable.
    if let shot = ProcessInfo.processInfo.environment["CLOTHESPEG_SETTINGS_SHOT"] {
        let page = ProcessInfo.processInfo.environment["CLOTHESPEG_SETTINGS_PAGE"]
        EditorPreview.renderSettings(to: shot, page: page)
        exit(0)
    }
    // Layout harness: render the space-preview window to a PNG and quit, at
    // whatever size it is given. `CLOTHESPEG_ZOOM_PIN` renders it pinned open
    // and `CLOTHESPEG_ZOOM_DARK` in the dark appearance.
    if let shot = ProcessInfo.processInfo.environment["CLOTHESPEG_ZOOM_SHOT"] {
        let env = ProcessInfo.processInfo.environment
        let width = Double(env["CLOTHESPEG_ZOOM_WIDTH"] ?? "") ?? ZoomPreview.size.width
        let height = Double(env["CLOTHESPEG_ZOOM_HEIGHT"] ?? "") ?? ZoomPreview.size.height
        EditorPreview.renderZoom(to: shot, size: CGSize(width: width, height: height),
                                 pinned: env["CLOTHESPEG_ZOOM_PIN"] != nil,
                                 dark: env["CLOTHESPEG_ZOOM_DARK"] != nil,
                                 hovering: env["CLOTHESPEG_ZOOM_HOVER"] != nil,
                                 opacity: Double(env["CLOTHESPEG_ZOOM_OPACITY"] ?? "") ?? 1)
        exit(0)
    }
    let app = NSApplication.shared
    // Translation probe: whether the system's engine is reachable from this
    // app at all, which pair is installed here, and how long a translation
    // takes. The one-point SwiftUI view it needs is the one part of P5 that
    // cannot be reasoned about from the SDK's headers.
    if let path = ProcessInfo.processInfo.environment["CLOTHESPEG_TRANSLATE_PROBE"] {
        let report: String
        if #available(macOS 15.0, *) {
            report = TranslateProbe.run()
        } else {
            report = "translate probe: this macOS has no Translation framework"
        }
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }
    // Keychain and wire probe: whether a key survives a round trip through the
    // login keychain from *this* binary — an ad-hoc signature cannot read back
    // what it wrote (errSecMissingEntitlement, -34018) — and, when a key is
    // handed in as `CLOTHESPEG_TRANSLATE_KEY`, whether the address answers with
    // a translation. Both are facts about the machine rather than about the
    // code, so neither can be settled by reading it.
    if let path = ProcessInfo.processInfo.environment["CLOTHESPEG_TRANSLATE_API_PROBE"] {
        let environment = ProcessInfo.processInfo.environment
        let report = TranslateAPIProbe.run(handedIn: environment["CLOTHESPEG_TRANSLATE_KEY"],
                                           keep: environment["CLOTHESPEG_TRANSLATE_KEEP"] != nil)
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }
    // Capture harness: everything the capture can be wrong about without a
    // pointer in the way — permission, window picking, the size of the grab,
    // and whether the crop lands where the rectangle said. Writes its lines to
    // the path given and quits.
    if let path = ProcessInfo.processInfo.environment["CLOTHESPEG_CAPTURE_SELFTEST"] {
        let report = CaptureSelfTest.run()
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }
    // Layout harness: draw the capture overlay to a PNG without showing it.
    // `CLOTHESPEG_CAPTURE_HOVER` lights a window-sized rectangle,
    // `CLOTHESPEG_CAPTURE_SELECT` a dragged one, `CLOTHESPEG_CAPTURE_RATIO=16:9`
    // locks the shape the way `R` does (any `CropAspect.title`, `free` included),
    // and `CLOTHESPEG_CAPTURE_PANEL` opens the ratio panel.
    // `CLOTHESPEG_CAPTURE_LONG=1240` shows the bar as it is while a long
    // capture is running, with that height in it, and
    // `CLOTHESPEG_CAPTURE_NOTE=1` puts the wrong-way-up note on its line — the
    // one thing that must not move the Done pill.
    if let shot = ProcessInfo.processInfo.environment["CLOTHESPEG_CAPTURE_PREVIEW"] {
        let env = ProcessInfo.processInfo.environment
        let aspect = env["CLOTHESPEG_CAPTURE_RATIO"]
            .flatMap { title in CropAspect.allCases.first { $0.title == title } } ?? .free
        print(CaptureSelfTest.render(to: shot,
                                     hovered: env["CLOTHESPEG_CAPTURE_HOVER"] != nil,
                                     selected: env["CLOTHESPEG_CAPTURE_SELECT"] != nil
                                        || env["CLOTHESPEG_CAPTURE_READ"] != nil,
                                     aspect: aspect,
                                     // `language` opens the shortlist; any
                                     // other value opens the shapes, which is
                                     // what this variable meant before there
                                     // were two of them.
                                     panel: env["CLOTHESPEG_CAPTURE_PANEL"]
                                        .map { $0 == "language" ? "language" : "ratio" },
                                     long: env["CLOTHESPEG_CAPTURE_LONG"].flatMap(Int.init),
                                     read: env["CLOTHESPEG_CAPTURE_READ"],
                                     note: env["CLOTHESPEG_CAPTURE_NOTE"]
                                        .map { $0 == "1" ? LongStitcher.noteTooFast : $0 },
                                     translated: env["CLOTHESPEG_CAPTURE_TRANSLATED"],
                                     armed: env["CLOTHESPEG_CAPTURE_ARM"],
                                     appearance: env["CLOTHESPEG_APPEARANCE"]))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
