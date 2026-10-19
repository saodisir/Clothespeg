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
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
