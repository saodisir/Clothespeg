import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var clipboardWatcher: ClipboardWatcher!
    /// The screenshot inbox's watcher, alive only while the inbox switch is
    /// on. It watches the app's own pictures folder, which macOS saves
    /// screenshots into once `Inbox.apply` has pointed it there.
    private var screenshotWatcher: ScreenshotWatcher?
    /// One watcher per folder the user asked to watch, keyed by the entry's
    /// id. Brought in line with the store by `syncFolderWatchers`.
    private var folderWatchers: [UUID: FolderWatcher] = [:]
    /// Asks every couple of seconds whether macOS still saves where the
    /// inbox pointed it. Nil while the inbox is off.
    private var inboxLocationGuard: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var scrollMonitor: Any?
    /// The same wheel seen system-wide, for the parts of the line the panel
    /// hands clicks through — see `watchScroll`.
    private var globalScrollMonitor: Any?
    /// The two thumb keys, which arrive as `otherMouseDown` and so never reach
    /// the wheel monitor. Local only — see `watchSideButtons` for why it does
    /// not also watch the whole system.
    private var sideButtonLocalMonitor: Any?
    private var zoomKeyMonitor: Any?
    private var zoomLocalMonitor: Any?
    private var zoomDismissMonitor: Any?
    /// Space, as Quick Look answers it: pressed while the pointer is on a
    /// card, it previews that card. Held only while it can be answered
    /// honestly — see `updateSpaceKey` for when that is, and
    /// `watchSpacePreview` for what tracks it.
    private var spaceHotKey: HotKey?
    /// The pointer's wanderings, watched only to know when the space key can
    /// honestly be armed or must be let go. Local and global both, for the
    /// same reason `watchScroll` keeps a pair: over the cards the event is
    /// this app's, over the pass-through everywhere else it is somebody's.
    private var spaceMoveMonitor: Any?
    private var spaceLocalMoveMonitor: Any?
    /// Space when this app itself is frontmost, where the Carbon key is
    /// deliberately disarmed and the local monitor answers instead.
    private var spaceLocalKeyMonitor: Any?
    /// Kept so the ticks can be refreshed when the filter changes on the line
    /// rather than in here.
    private var filterMenuRef: NSMenu?
    private var clipboardKey: HotKey?
    /// The two doors: ⌃⌥C brings the line down on what you copied, ⌃⌥N
    /// brings it down on the notes. Held here rather than in a local, for
    /// the reason every `HotKey` is: a key is what its own registration is
    /// kept alive by, so one that is let go is a shortcut that stops
    /// working.
    private var notesKey: HotKey?
    /// The two doors that act on a line already down — the one that writes a
    /// note and the one that keeps the rope down. Carbon hot keys after all,
    /// but registered only while they can be answered honestly: the line is
    /// down, and this app is not the one the user is typing into. Held in a
    /// dictionary so a disarm is a real unregister — each instance takes its
    /// registration with it.
    private var panelKeys: [Door: HotKey] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// Throttles the notch-trigger log to one line a second while the
    /// pointer rests there, so a refused gesture says why without a flood.
    private var lastTriggerLog = Date.distantPast
    /// The same, for the wheel: one line a second of what a notch is worth.
    private var lastWheelLog = Date.distantPast
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?

    /// Whether the pointer was judged to be on the pill on the last pass.
    ///
    /// Kept so the answer can be sticky. The rectangle the pill reports is a
    /// few points off where the pill is drawn, so a pointer resting on one
    /// spot can read as inside on one pass and outside on the next — and each
    /// flip is the panel letting go of the mouse, which redraws the material
    /// it is made of. That is the strip flickering light and dark while the
    /// hand is not moving.
    private var pointerOnPill = false

    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Propped down: the line stays until released rather than retracting on
    /// its own. The "panel" the user wants is just the rope in this state.
    private var propped = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the notch. Off, only the shortcut and the
    /// menu open it.
    ///
    /// The key changed with it, from the menu bar this used to watch. The old
    /// key is still read on the way in, so a setting chosen before the move
    /// survives it rather than quietly snapping back to the default — the same
    /// `Off`/`On` inversion as before, only on a different key.
    static var opensFromNotch: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "notchRevealOff") != nil {
                return !defaults.bool(forKey: "notchRevealOff")
            }
            // First run after the change: no answer under the new key, so the
            // old one is the answer if it was ever asked.
            return !defaults.bool(forKey: "menuBarRevealOff")
        }
        set { UserDefaults.standard.set(!newValue, forKey: "notchRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    /// One line along the top of the screen, and only one.
    ///
    /// Two copies of this app at once put two lines in the same place, each
    /// watching the clipboard and each keeping its own rope. From the chair
    /// that does not read as two apps — it reads as one app misbehaving: a
    /// card that arrives twice, a hint whose words and its glass part
    /// company halfway through a motion, a rope that flickers when the
    /// deck switches. That last one was chased through fourteen attempts
    /// at the hint's own animation before anybody thought to count the
    /// processes.
    ///
    /// So a launch asks what is already running under this bundle
    /// identifier and asks it to quit, rather than quitting itself and
    /// leaving the older build up there. The one started last is the one
    /// meant to be running: it is the one that was just rebuilt, or the
    /// one just dragged into Applications. The one going goes out through
    /// its own `applicationWillTerminate`, so the screenshot inbox is put
    /// back where it was found before this launch points it somewhere
    /// else — the two cannot fight over the same setting on the way past
    /// each other.
    ///
    /// Asked by identifier and not by name, because Lite and the full app
    /// are two identifiers and so two apps as far as this is concerned;
    /// each is allowed its one.
    ///
    /// A debug build only. A released app has no reason to question what
    /// else is running: it was started once, from Applications, by
    /// somebody who meant it. It is the build you are testing that gets
    /// started over and over from the same place, and it is that one that
    /// keeps leaving a copy of itself behind.
#if DEBUG
    private func beTheOnlyInstance() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where other.processIdentifier != mine {
            // Kill the stale copy at once rather than ask it to quit: a
            // graceful quit leaves its menu-bar item up while it winds down,
            // and the status item we are about to hang can be torn out with
            // it (see the deferred setUpStatusItem below).
            other.forceTerminate()
        }
    }
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        // Before anything is hung, watched or pointed: whatever is already
        // up there has to come down first, or there are two of everything.
        beTheOnlyInstance()
#endif
        diagLog("App launched")
        line.onPropToggle = { [weak self] in self?.toggleProp() }
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        // As deep as whatever is on it. Asked through a closure rather than
        // set once, because the answer changes with the deck — a note is as
        // tall as its contents and the clipboard's cards are all one size —
        // and because the panel is placed from half a dozen places, none of
        // which is a good place to have to remember this.
        panel.depthProvider = { [weak self] in
            Layout.depth(for: self?.line.deck ?? .clipboard)
        }
        panel.placeOnScreen()
        updateCapacity()

        // The search writes through to the line rather than the other way
        // round: there are two copies of the field — one on the pill, one in
        // the window that can take a key — and the line is the one thing both
        // of them can be given.
        SearchController.shared.model.line = line
        // The notes, likewise, and for the same reason. The window a note is
        // written in is opened from three places — the shortcut, the menu and
        // the card itself — and all three want the one line the app was
        // launched with.
        NoteController.shared.line = line

        // The line, reachable from the settings window. Handed over once here
        // rather than threaded through the view tree, because the window that
        // offers to clean up needs the same thing the launch cleans up with,
        // and there is only one line.
        LineKeeper.line = line
        // The watched folders, likewise reachable from the settings window:
        // the page adds and removes them, and the app brings the watchers in
        // line with the list it keeps.
        LineKeeper.folderWatchSync = { [weak self] in self?.syncFolderWatchers() }
        // And the paper, which is chosen in that window and redrawn on this
        // line: the setting writes through the line, so the change is on the
        // cards the moment it is made rather than at the next launch.
        SettingsController.shared.line = line

        // The chosen appearance, back on before anything is on screen. Set on
        // the application, so it reaches the panel, the pill, the search
        // window and the settings window in one go — and so a choice made
        // last week is the first thing this launch does rather than the last.
        Appearance.restore()

        clipboardWatcher = ClipboardWatcher { [weak self] payload, origin, rich in
            self?.hang(payload, origin: origin, rich: rich)
        }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        // The screenshot inbox, when the user asked for it and a previous
        // launch left it on: macOS goes back to saving into this app's own
        // folder, and the watcher hangs whatever lands there. The apply comes
        // before the watcher, so nothing lands in a folder nobody is watching.
#if !APPSTORE_LITE
        if Inbox.screenshotInboxEnabled {
            Inbox.apply()
            startScreenshotWatcher()
            startInboxLocationGuard()
        }
#endif
        watchForTermination()

        // The folders the user asked to watch: their watchers come back with
        // the app, each ticket cashed in fresh.
        syncFolderWatchers()

        // Two doors, one per rope, and the ids are what tell the handlers
        // apart. Each of these installs a handler on the application and
        // every handler hears every hot key, so the id carried in the event
        // is the only thing that says which one was pressed.
        //
        // The keys are the settings' answer — ⌃⌥C and ⌃⌥N until recorded
        // otherwise — and the same answer the menu reads, so the two cannot
        // disagree. The writing itself opens from the line now: the plus
        // above the middle of the notes' rope is that door.
        registerHotkeys()

        // Hung just after launch, not inline: beTheOnlyInstance (DEBUG) has
        // just force-terminated any earlier copy, and its menu-bar item lingers
        // for a beat as the process dies. Adding ours in that window can make
        // macOS remove it along with the old one — the bug behind a debug
        // relaunch showing no menu-bar icon. By the time this fires the stale
        // copy is gone, so ours sticks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setUpStatusItem()
        }
        watchMenuBarClicks()
        watchOutsideClicks()
        watchScroll()
        watchSideButtons()
        watchZoomKey()
        watchSpacePreview()
        watchFrontmost()

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // The panel's depth is a question about the deck, so the deck's
        // change is what re-asks it — here, once, rather than at each of the
        // places the deck can change from: a shortcut, a hover on the notch,
        // a note hung from the editor. Miss one and the panel keeps the old
        // depth, which is a note with its bottom cut off.
        line.$deck
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.panel.placeOnScreen() }
            .store(in: &cancellables)
        // A note that has just been written is the thing to look at, so the
        // line comes down for it the way it comes down for a copy. Said by the
        // line rather than asked of it: only the line knows whether anything
        // was hung at all, and the window finishes a note in three ways of
        // which one ends with a note on the line.
        NotificationCenter.default.addObserver(forName: .noteHung, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.comeDown(on: nil) }
        }
        // The reminder side of the notes: the scheduler answers the system's
        // deliveries from here on, and a ring brings the rope down with the
        // notes deck facing, the way a note just written does — a reminder
        // that rings quietly behind a retracted rope is a clock, not a
        // reminder.
        ReminderScheduler.shared.activate()
        // The in-app ring reads the notes from here on: the rope comes down
        // for a due reminder whether or not the system ever draws a banner.
        let readNotes: () -> [(id: UUID, note: Note)] = { [weak self] in
            guard let self else { return [] }
            return self.line.notes.filter { !$0.falling }.compactMap { item -> (id: UUID, note: Note)? in
                guard case .note(let note) = item.payload else { return nil }
                return (item.id, note)
            }
        }
        ReminderScheduler.shared.noteProvider = readNotes
        NotificationCenter.default.addObserver(forName: ReminderScheduler.firedNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let id = note.userInfo?["id"] as? UUID else { return }
                self.line.deck = .notes
                self.openPinned()
                self.line.noteReminderArrived(id)
            }
        }
        // The notes came back from disk before this ran, but nothing had
        // rebuilt their timers: `reconcile` used to walk through `saveNotes`
        // only, so after a relaunch a reminder that was already set stayed
        // silent — no rope, no bell — until the note was edited again. That
        // is how a daily reminder could sit through a whole morning unseen.
        // Agreeing once here hands every live reminder its timer back, and
        // the system's pending list follows the notes as it always does.
        ReminderScheduler.shared.reconcile(with: readNotes())
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }

        // An empty line has nothing to show at launch, so nothing above has
        // called refresh — and refresh is what starts the pointer watch. One
        // call here keeps the notch hearable from the first second, cards or
        // no cards.
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The screenshot inbox's takeover of the macOS screenshot settings is
        // undone on the way out, so macOS is never left saving into a folder
        // nobody is watching.
        if Inbox.screenshotInboxEnabled { Inbox.restore() }
    }

// MARK: Clipboard mode

    /// Pausing the line does not mean quitting it: the state is remembered so
    /// the next copy hangs without being asked for again.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    // MARK: Screenshot inbox

    /// The opt-in return of Tendedero's takeover. On, macOS saves captures
    /// into this app's own folder and the watcher hangs them as they land;
    /// off, the settings macOS held first are put back and the folder is
    /// watched by nobody, as it always was for anyone who never opened the
    /// switch.
    private func setScreenshotInbox(_ on: Bool) {
#if APPSTORE_LITE
        // The Lite build never takes over where macOS saves screenshots:
        // changing a system preference from inside the sandbox is not the
        // store's idea of an app's business. Watched folders are the way in.
        return
#else
        Inbox.screenshotInboxEnabled = on
        if on {
            Inbox.apply()
            startScreenshotWatcher()
            startInboxLocationGuard()
        } else {
            inboxLocationGuard?.invalidate()
            inboxLocationGuard = nil
            screenshotWatcher?.stop()
            screenshotWatcher = nil
            Inbox.restore()
        }
#endif
    }

    /// The guard that keeps the inbox honest about its own tick. The user
    /// can move macOS's save location at any time — ⌘⇧5's menu writes the
    /// same preference this inbox does — and when that happens their newest
    /// answer wins: the inbox switches itself off, the tick in the menu goes
    /// with it, and the location they chose is left exactly where they put
    /// it. A minute between asks: nothing is lost while the answer is stale
    /// — captures land wherever the user pointed macOS — so the timer only
    /// keeps the flag honest, and the menu asks again the moment it opens.
    private func startInboxLocationGuard() {
        guard inboxLocationGuard == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard Inbox.screenshotInboxEnabled, Inbox.locationMovedAway() else { return }
                self?.setScreenshotInbox(false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        inboxLocationGuard = timer
    }

    private func startScreenshotWatcher() {
        guard screenshotWatcher == nil else { return }
        let watcher = ScreenshotWatcher(
            folder: Inbox.folder,
            onNew: { [weak self] url in self?.hang(.image(url)) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        screenshotWatcher = watcher
    }

    // MARK: Watched folders

    /// Brings the watchers in line with the list in the store: one watcher
    /// per enabled entry, none for a folder taken off or switched off, and a
    /// fresh watcher over a stale one — the re-pick the settings page offers
    /// writes a new ticket under the same id, and this is what turns it back
    /// into a watch. Called at launch and after every change the settings
    /// page makes.
    private func syncFolderWatchers() {
        let entries = FolderWatchStore.entries
        for (id, watcher) in folderWatchers
        where watcher.isStale || !entries.contains(where: { $0.id == id && $0.enabled }) {
            watcher.stop()
            folderWatchers[id] = nil
        }
        for entry in entries where entry.enabled {
            guard folderWatchers[entry.id] == nil else { continue }
            let watcher = FolderWatcher(entry: entry) { [weak self] url in
                // A copy, not a reference: the card owns its file the way
                // every copied picture does, and outlives the watch.
                guard let copy = Inbox.copyImage(from: url) else { return }
                self?.hang(.image(copy))
            }
            watcher.start()
            folderWatchers[entry.id] = watcher
        }
    }

    /// SIGTERM and SIGINT do not run `applicationWillTerminate`, and a kill
    /// from outside must leave macOS pointing at the folder it saved into
    /// before this app was born. The sources live in `signalSources`, which
    /// the app has carried for exactly this.
    private func watchForTermination() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.quitRestoringSettings()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func quitRestoringSettings() {
        if Inbox.screenshotInboxEnabled { Inbox.restore() }
        exit(0)
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        guard line.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: Hanging what was copied

    /// Something was copied. The line comes down, and the item hangs on it
    /// with the swing a card gets when it is pegged up.
    ///
    /// Tendedero flew a new screenshot in from the spot it was taken, which
    /// needed the capture area macOS records in the file. A copy has no such
    /// place — you took a screenshot long before you copied it — so nothing
    /// flies in here: the card arrives the way the wind brings everything
    /// else in.
    private func hang(_ payload: Payload, origin: Origin = Origin(), rich: RichText? = nil) {
        comeDown(on: nil)
        guard line.hang(payload, origin: origin, rich: rich) != nil else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        let width = panel.frame.width
        // The same window the view lays out: only the cards on show, in the
        // same order, so a card measured here is where it is hanging. Using
        // the whole history here would put the hit area of a card that is
        // panned off somewhere it is not.
        let shown = line.visibleItems(pagerRoom)
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return nil }
        let x = Layout.x(index: index, count: shown.count, width: width,
                         pitch: Layout.pitch(for: line.deck))
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let item = shown[index]
        let size = PayloadCard.outerSize(of: item)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The pointer is watched for the life of the app, not for the life
        // of a want. The notch gesture has to stay hearable when the line is
        // empty — which is exactly when `wanted` is false — or an emptied
        // line can never be called back by the one gesture that reaches it.
        startMouseTracking()
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // The panel's own keys follow the line: nothing to answer when the
        // line is up there folded away, and the moment it comes down they
        // should work, wherever the pointer happens to be.
        updatePanelKeys()
        // The search window is over the pill, so it is only somewhere when the
        // pill is. A field left up over an app with no line under it is a
        // search for nothing.
        //
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            SearchController.shared.lineDidShow()
            if isPresent { panel.orderFrontRegardless() }
        } else {
            SearchController.shared.lineDidHide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed { putAway() } else { openPinned() }
    }

    /// A door into one half of the line: the deck the key names comes down,
    /// and a press on the door already open puts the line away. Two keys
    /// that each answer one question — where is the clipboard's rope, where
    /// are the notes — rather than one key that cycles through answers.
    private func showDeck(_ deck: Line.Deck) {
        if line.deck == deck, isRevealed {
            putAway()
        } else {
            line.deck = deck
            openPinned()
        }
    }

    /// The line goes back up, and takes itself off the screen with it when
    /// there is nothing left on it.
    ///
    /// The one way the line is put away by hand, whether the shortcut, the
    /// menu or the second deck brought it down. Which door was used is not
    /// something the closing has any business knowing, and the day it starts
    /// to matter is the day the three of them stop agreeing.
    private func putAway() {
        diagLog("Line put away, cards on the line: \(line.liveCount)")
        propped = false
        line.propped = false
        setRevealed(false)
        // An empty line has nothing to come back for, so it stops being
        // somewhere at all. A line with something on it stays ordered in and
        // tucked away, which is what lets the notch bring it straight back.
        guard line.liveCount == 0 else { return }
        keepOpen = false
        wanted = false
        refresh()
    }

    /// The line comes down on purpose and stays until it is put away.
    private func openPinned() {
        keepOpen = true
        wanted = true
        panel.placeOnScreen()
        updateCapacity()
        refresh()
        reveal(pinned: true)
    }

    /// Props the rope down, or lets it go. The "panel" the user wants is the
    /// rope in this state: it comes down and does not retract on its own — no
    /// pointer-away timer, no outside-click dismissal, no menu-bar dismissal.
    ///
    /// Propping on brings it down if it is not already; letting it go returns
    /// it to the ordinary rope, which puts itself away the way a gesture-brought
    /// line does.
    private func toggleProp() {
        prop(on: !propped)
    }

    private func prop(on: Bool) {
        guard on != propped else { return }
        if on {
            propped = true
            line.propped = true
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        } else {
            propped = false
            line.propped = false
            putAway()
        }
    }

    /// A note, in the window a note is written in.
    ///
    /// Nothing goes on the line yet and the deck is not switched yet: the note
    /// does not exist until the window is done with it, and a deck that
    /// switched over to show a card nobody has written would be an empty line
    /// pretending to be a note.
    @objc private func newNote() {
        NoteController.shared.beginNew()
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    /// How long the cursor rests in the notch before the line comes down.
    /// The setting's answer, not a constant — see `DropDeck.Rest`.
    private static var revealDelay: TimeInterval { DropDeck.rest.seconds }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    ///
    /// The whole bar and not the notch, because a click in the notch is a click
    /// that missed everything — there is nothing up there to open — while a click
    /// next to it opened something. Both mean the pointer went to the system and
    /// the line should not follow it back down.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, TriggerBand.menuBar(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                diagLog("Menu-bar click: notch trigger suppressed")
                if self.isRevealed, !self.propped {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// A click anywhere outside the line puts it away.
    ///
    /// The line came down on purpose and stays while it is being used; the
    /// click that lands somewhere else is the answer to the question of
    /// whether it still is. Watched rather than timed, because a timer
    /// would pull the line out from under a hand that had stopped to read.
    ///
    /// Where "somewhere else" starts is one band for both decks, as deep as
    /// the clipboard's panel and the same slack below it. The notes' panel
    /// hangs deeper, but its extra glass no longer holds the dismissal off:
    /// a press on it falls through the panel and lands in whatever is under
    /// it, which is a click somewhere else by any reading of the words. What
    /// keeps a deep note card safe is not the band but the card itself — a
    /// press on a card is answered by one of this app's windows and never
    /// reaches the outside test at all, and the band's edges are checked
    /// against the cards' own rects in case a tall card reaches past it.
    /// That is why the line can put its cards where they fit and still put
    /// its dismissal where the hand expects it.
    private func watchOutsideClicks() {
        // Only the global monitor is here, and that is the whole design: an
        // event this app received went to one of the line's things — a card,
        // the note's editor, the zoom — and wherever it landed it is not a
        // click somewhere else. The old zone approximated the same rule by
        // hoping every own window sat over it; ownership is not an
        // approximation.
        let globalHandler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRevealed, !GrabView.isDragging, !self.propped else { return }
                let mouse = NSEvent.mouseLocation
                // The band both decks answer to.
                let top = self.panel.screen?.frame.maxY ?? self.panel.frame.maxY
                let band = CGRect(x: self.panel.frame.minX,
                                  y: top - Self.dismissDepth,
                                  width: self.panel.frame.width,
                                  height: Self.dismissDepth)
                guard !band.contains(mouse) else { return }
                // A tall note card reaches past the band, and a press on it
                // is a press on the card. The rects are the ones the pass-
                // through already reads — same space, same flip, and the
                // same few points of slack — so where a click is caught to
                // be answered and where it is kept from dismissing say the
                // same thing about where the cards are.
                let local = self.panel.convertPoint(fromScreen: mouse)
                let flipped = CGPoint(x: local.x, y: self.panel.frame.height - local.y)
                let overCard = self.line.hitRects.values.contains {
                    $0.insetBy(dx: -4, dy: -4).contains(flipped)
                }
                guard !overCard else { return }
                // A press on the pager itself — now where the prop toggle
                // lives — is answered by the panel, never reaching this test,
                // so propped is guarded at the top and the pager's hit test
                // keeps the toggle safe below it.
                self.putAway()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: globalHandler) {
            clickMonitors.append(global)
        }
    }

    /// How deep the click that keeps the line up reaches, on either deck:
    /// the clipboard's panel plus the same slack below it that the old zone
    /// carried. The notes' deeper panel is about room for its cards, not
    /// about where a dismissal is judged.
    private static let dismissDepth: CGFloat = Layout.clipboardDepth + 50

    /// Whether the pointer is somewhere in the strip the line occupies.
    ///
    /// The one question three answers read: the global wheel monitor that
    /// catches swipes over the panel's empty parts, the wheel that turns a
    /// vertical roll into a page turn, and the side buttons. All three ask
    /// the same thing — is the hand inside the line's own band — and they
    /// have to agree, because a swipe that paged with the pointer over the
    /// line but did not page with the pointer a card's width away from it
    /// would be a rule nobody could hold in their head.
    ///
    /// The band is `dismissDepth`, the same depth the outside click uses,
    /// rather than a depth of its own. Two answers to "where does the line
    /// end" that could disagree would be one more thing to reason about, and
    /// the panel hangs at the top edge of one screen either way — the slack
    /// under it that the notes' deeper panel has is room for cards, not a
    /// different rule about where a gesture lands.
    private func inLineBand() -> Bool {
        let mouse = NSEvent.mouseLocation
        let top = panel.screen?.frame.maxY ?? panel.frame.maxY
        return CGRect(x: panel.frame.minX,
                      y: top - Self.dismissDepth,
                      width: panel.frame.width,
                      height: Self.dismissDepth).contains(mouse)
    }

    /// Where the pointer is in this panel's own space, flipped the way SwiftUI
    /// draws it.
    ///
    /// The hit rectangles and the pill's are reported in SwiftUI's space, whose
    /// origin is the top left; AppKit puts the mouse's at the bottom left.
    /// Three readers need this and all three would get it wrong the same way,
    /// so it is written once.
    private func pointerInLine() -> CGPoint {
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        return CGPoint(x: local.x, y: panel.frame.height - local.y)
    }

    /// The card under the pointer, if any, and whether it can be scrolled
    /// vertically by a wheel of its own.
    ///
    /// A note taller than its paper scrolls itself (`GrabArea.scrollWheel`,
    /// which answers before any monitor of ours sees the wheel), and a wheel
    /// that paged the line instead would leave a long note unreadable. So the
    /// answer decides whether a vertical roll is ours to take.
    ///
    /// Arranged here rather than read off the card, because the card's answer
    /// lives on a view this class cannot reach. Both sides arrange the same
    /// note through the same pure function, so the two agree by construction
    /// rather than by luck — `arrange` is what `GrabArea` calls when it sets
    /// `noteScrollMax` in the first place.
    private func pointerOnScrollableCard() -> Bool {
        guard let id = line.hitRects.first(where: {
            $0.value.insetBy(dx: -4, dy: -4).contains(pointerInLine())
        })?.key, let note = line.onLine.first(where: { $0.id == id })?.payload.note
        else { return false }
        let arrangement = NoteCardLayout.arrange(note)
        return max(0, arrangement.fullHeight - arrangement.height) > 0
    }

    /// Panning the line to reach what is further back.
    ///
    /// Two monitors, because the panel hands mouse events through: `passThrough`
    /// sets `ignoresMouseEvents` wherever the pointer is not on a card, the
    /// pill or the plus, so everywhere else the wheel goes straight to the app
    /// underneath and a local monitor never hears of it. A **global** monitor
    /// sees the whole system's mouse events regardless of what any window does
    /// with them, so it hears the wheel in the gaps between cards — which is
    /// where a swipe has to work, because a row of small pictures leaves wide
    /// gaps and a hand asked to land on a card to move the line is a hand
    /// asked for precision it is not good at.
    ///
    /// The local one is kept alongside rather than replaced: it sees events
    /// delivered to this app, which the global one cannot, and a swipe that
    /// starts on a card and leaves it mid-gesture belongs to one run of
    /// handlers rather than two.
    ///
    /// `ignoresMouseEvents` is deliberately left alone. It is the only thing
    /// keeping a click on the empty part of the panel from being eaten, and
    /// the empty part can be a web page or a text field — so the line takes
    /// the wheel and gives the click back, which is what this pairing buys.
    private func watchScroll() {
        // A trackpad's wheel and a mouse's wheel are the same event carrying
        // very different amounts of travel, and one threshold cannot serve
        // both. A trackpad sends a stream of small precise deltas — a flick
        // crosses sixty points in a couple of events — so sixty is one card.
        // A mouse's wheel sends about one point per notch, so sixty points is
        // sixty notches, and reaching the next card takes a second of turning
        // the wheel. That was reported as the paging being slow, and it was
        // this: the number had only ever been checked against a trackpad.
        //
        // So the wheel's own units are the answer. One notch is one card,
        // which is what a wheel is for, and `hasPreciseScrollingDeltas` is
        // what says which kind of wheel it was. The two paths share the step
        // that decides which way and the `pan` that clamps it; only the
        // distance a card costs differs.
        let pan: (CGFloat, Bool) -> Void = { [weak self] travelled, precise in
            MainActor.assumeIsolated {
                guard let self, self.isRevealed else { return }
                let room = self.pagerRoom
                guard self.line.items.count > room else { return }
                self.panAccumulator += travelled
                // One card's worth of travel, measured in whatever the device
                // sends. A trackpad is asked for sixty points; a wheel is asked
                // for one notch, which macOS reports as a tenth of a point, so
                // one turn of the wheel is one card.
                let needed = precise ? Self.panThreshold : Self.wheelThreshold
                guard abs(self.panAccumulator) >= needed else { return }
                // How many cards the travel so far is worth. A trackpad always
                // moves one card and keeps the change of direction for the next
                // one; a wheel is counted, because a fast turn arrives as one
                // event carrying many notches — turning hard would otherwise
                // skip most of the line.
                let cards: Int
                if precise {
                    cards = 1
                } else {
                    cards = min(Self.wheelCardsPerEvent,
                                max(1, Int((abs(self.panAccumulator) / needed).rounded(.down))))
                }
                // Pulling to the right drags the line with it and brings what
                // is further back into view, the way a drawer opens the way
                // you pull it. Both senses are the same gesture read the
                // other way round, so the choice is only which feels natural.
                let direction: Int
                if Self.panReversed { direction = self.panAccumulator > 0 ? -1 : 1 }
                else { direction = self.panAccumulator > 0 ? 1 : -1 }
                // Only the travel that was spent is taken off, so a hard turn
                // over the cap keeps the rest for the events that follow
                // rather than dropping it.
                //
                // Taken off by **magnitude, not by the direction travelled**:
                // `panReversed` decides which way a positive delta moves the
                // line, and subtracting a signed amount applies that flip a
                // second time — the accumulator grew on one way and shrank on
                // the other, so one direction never built up and the wheel
                // answered in one direction only. Which was reported as
                // "only one of the two directions works", from a change whose
                // whole point had been to keep a hard turn from being swallowed.
                // The sign that belongs here is the sign the fingers moved,
                // which is the sign the accumulator already carries.
                let spent = CGFloat(cards) * needed
                self.panAccumulator += self.panAccumulator < 0 ? spent : -spent
                // Whatever a hard turn overran by is kept, but only a few
                // cards' worth. What it is not allowed to be is a hundred
                // notches: that left every notch after a fast turn paging
                // against an end it could not move, which is what made the
                // wheel look broken at either end of the line and only after
                // turning back.
                let cap = Self.wheelCarryOver * needed
                if abs(self.panAccumulator) > cap {
                    self.panAccumulator = self.panAccumulator < 0 ? -cap : cap
                }
                // Panning is looking at the line, so the control on it closes
                // the way it does when the copy is over.
                NotificationCenter.default.post(name: .filterCollapsed, object: nil)
                let before = self.line.panOffset
                self.line.pan(by: direction * cards, fits: room)
                // At an end and not moving is an answer: the line has nothing
                // further this way, and `pan` clamped rather than refused.
                // Letting travel pile up there is what made the first real
                // notch after turning back seem to do nothing — it went into
                // the accumulator against a wall instead of onto the line.
                // So an end spends the travel rather than keeping it, which
                // is also what the hand meant by leaning on the wheel there.
                if self.line.panOffset == before {
                    self.panAccumulator = 0
                }
            }
        }

        // The wheel, wherever it lands. `owned` is the whole question:
        //
        // Over a card or the pill the panel is not letting the mouse through,
        // so the wheel is this app's and the local monitor is free to answer
        // with nothing — the line can have it outright. Everywhere else the
        // panel is handing the event to the app underneath, and a global
        // monitor can only watch such an event, never take it back. Paging a
        // wheel there means the page below scrolls as well, which was reported
        // as the rope stealing the scroll from the app under it.
        //
        // So a vertical roll only pages where the wheel is ours: the pill
        // above all, where "3–7 / 40" already says which way is forward, and
        // any card. In the gaps the vertical wheel belongs to the app below
        // and stays with it — including a long note, which scrolls itself.
        //
        // A horizontal wheel is a different matter. Almost nothing scrolls
        // sideways, so a page that also moves a little on a horizontal flick
        // is not a page that looks wrong, and the gaps are exactly where a
        // swipe has to work — a row of small pictures leaves wide gaps, and a
        // hand asked to land on a card to move the line is a hand asked for
        // precision it is not good at.
        let wheel: (NSEvent, Bool) -> Void = { [weak self] event, owned in
            guard let self else { return }
            let horizontal = event.scrollingDeltaX
            let vertical = event.scrollingDeltaY
            // Which kind of wheel this is, from the event itself rather than
            // from the device: the two can be attached at once, and a trackpad
            // resting under the pointer of a mouse should still flick.
            let precise = event.hasPreciseScrollingDeltas
            // What a notch is actually worth, written down once per shape of
            // wheel rather than assumed: the threshold below is a guess about
            // it, and a mouse reporting three points per notch would page
            // three times where one notch was turned. Logged at most once a
            // second so a held wheel does not flood the file.
            let now = Date()
            if !precise, now.timeIntervalSince(lastWheelLog) >= 1 {
                lastWheelLog = now
                diagLog("Wheel notch: dy=\(vertical) dx=\(horizontal) precise=\(precise) owned=\(owned)")
            }
            if abs(horizontal) <= abs(vertical) {
                // A vertical roll is only the line's where the line is holding
                // the mouse. `owned` already says so, and the note check is
                // belt and braces for the card that scrolls itself.
                guard owned, self.inLineBand(), !self.pointerOnScrollableCard() else { return }
                pan(vertical, precise)
                return
            }
            pan(horizontal, precise)
        }

        // The half that can keep a wheel to itself: over the cards and the pill
        // the panel is not letting the mouse through, so a wheel there is ours
        // and is swallowed rather than passed on. Swallowing is what stops the
        // page below from scrolling too — which was the whole point of the
        // `owned` distinction above.
        let handler: (NSEvent) -> NSEvent? = { event in
            MainActor.assumeIsolated { () -> NSEvent? in
                wheel(event, true)
                // Returned rather than swallowed where the panel is holding
                // the mouse: the wheel may still be one the card or the pill
                // wants to answer itself — a long note scrolls itself, and its
                // `scrollWheel` is reached through this same path. The note
                // check inside `wheel` has already declined to page, so
                // nothing is lost by letting the event carry on.
                return event
            }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: handler) {
            scrollMonitor = local
        }
        // The global half watches the wheel that the panel handed to the app
        // underneath, and can do nothing about it — its handler takes no
        // return value, because the event was never this app's to begin with.
        // So it pages on the horizontal only, where a little sideways movement
        // in another app is invisible, and leaves every vertical wheel to
        // whoever received it.
        //
        // The two do not see the same wheel. AppKit hands a global monitor only
        // the events going to *other* applications, which is exactly the
        // partition that makes the pair complete rather than doubled: the
        // local one sees the wheel over a card, the global one sees the wheel
        // in the gaps the panel let through. Were both to fire on one wheel,
        // `panAccumulator` would gain the same travel twice and a single flick
        // would skip a card — so the log line below says which half was
        // installed, and a flick that moves two is the symptom of the two ever
        // meeting.
        let globalHandler: (NSEvent) -> Void = { event in
            MainActor.assumeIsolated { wheel(event, false) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: globalHandler) {
            globalScrollMonitor = global
        }
        diagLog("Wheel monitors: local=\(scrollMonitor != nil) global=\(globalScrollMonitor != nil)")
    }

    /// The side buttons, paged the way the two thumb keys read.
    ///
    /// `otherMouseDown` rather than the wheel, and this is not a detail: a
    /// mouse's thumb keys arrive as button 3 (back) and 4 (forward), which is
    /// a **different event channel entirely** — `watchScroll` never hears one.
    /// That is why they did nothing before this, and it is why they are here
    /// rather than folded into the wheel above.
    ///
    /// They need no direction of their own to be worth having, because the
    /// buttons already say which way is which: back pages towards the newer
    /// cards, forward towards the older. The middle button is not in on this
    /// — it has no side to it, so paging with it would mean inventing which
    /// way it goes, and it already means something in most of the apps the
    /// line floats over.
    ///
    /// Answered only inside the band, so the same two keys keep meaning back
    /// and forward in the browser underneath.
    private func watchSideButtons() {
        // A thumb key that another app has taken — Flyring answers its own on
        // these, and so may anything else — is not stopped by anything said
        // here, because Carbon hot keys are registered with the system and
        // fire whatever this app does or does not see. The only place a press
        // *can* be taken back is inside this app's own windows, where a local
        // monitor is allowed to answer with nothing. So the two places are
        // treated differently on purpose:
        //
        // - Over a card or the pill the panel is not letting clicks through,
        //   the press is ours and the local monitor swallows it. Nothing else
        //   sees it, so the other app's shortcut does not also fire.
        // - Over the empty part the panel is letting through, the press belongs
        //   to whatever is underneath and we do not answer at all. Not
        //   because we could not — the global monitor sees it — but because
        //   a key that means "bring Flyring up" everywhere on this machine
        //   should not stop meaning that, just because a rope happens to be
        //   hanging at the top of the screen.
        //
        // So the side keys page where the cards are, and stay out of the way
        // everywhere else. The wheel is the opposite and stays global, because
        // a wheel has no other meaning and the empty part is exactly where a
        // paging gesture has to work.
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isRevealed else { return }
                // The switch, asked before anything else: off is the default and
                // means the thumb keys are none of this app's business.
                guard Self.sideButtonPaging else { return }
                // Whether a global monitor hears anything at all depends on the
                // machine's Accessibility permission, and an app with no
                // permission still installs one successfully and then is sent
                // nothing — which looks exactly like a mouse whose thumb keys
                // do not work. So the first press that arrives anywhere says
                // so in the log, since "it never arrived" is the one failure
                // with nothing on screen to look at.
                guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return }
                diagLog("Side button \(event.buttonNumber) heard; band=\(self.inLineBand())")
                guard self.inLineBand() else { return }
                let room = self.pagerRoom
                guard self.line.items.count > room else { return }
                // 3 is the thumb key nearer the back of the mouse, 4 the one
                // nearer the front. Cards run newest first, so back steps
                // towards the newer end and forward towards the older.
                let step = event.buttonNumber == 3 ? -1 : 1
                NotificationCenter.default.post(name: .filterCollapsed, object: nil)
                self.line.pan(by: step, fits: room)
            }
        }
        // The one that can answer with nothing, and so keeps the other app's
        // shortcut from firing as well. Over the cards the panel is holding
        // the mouse already, so this is where a press is ours to keep.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { event in
            MainActor.assumeIsolated { handler(event) }
            return event
        }) {
            sideButtonLocalMonitor = local
        }
        diagLog("Side button monitors: local=\(sideButtonLocalMonitor != nil)")
    }

    /// Whether pulling the line right walks towards the past. A setting
    /// rather than a fixed direction, because both readings are defensible
    /// and which one feels right is not something to decide for the user —
    /// it lives in the settings now, with the rest of the taste questions.
    /// Static, because the scroll monitor and the settings page are two
    /// readers of one answer and neither owns the other.
    static var panReversed: Bool {
        // Reversed by default: the direction most hands call natural on
        // first try. Only an explicit answer — the settings switch — says
        // otherwise, so the default is what an absent answer means.
        get { (UserDefaults.standard.object(forKey: "panReversed") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "panReversed") }
    }

    /// Whether the mouse's two thumb keys page the line.
    ///
    /// **Off unless the user asks for it**, and the reason is not caution
    /// about the feature but about what a side key is: it is a key another app
    /// can already have taken. A global shortcut is registered with the system,
    /// which hands it the event before any window of ours sees it, so this one
    /// cannot page quietly and leave the other one alone — both answer, and
    /// nothing said here can stop that.
    ///
    /// So the switch is honest about it. A feature that is off by default is
    /// simply not there; one that is on and silently does nothing is the thing
    /// that makes a machine feel haunted. The wheel, the arrows and the pill
    /// all page without this, so nothing is lost by leaving it alone.
    static var sideButtonPaging: Bool {
        get { UserDefaults.standard.bool(forKey: "sideButtonPaging") }
        set { UserDefaults.standard.set(newValue, forKey: "sideButtonPaging") }
    }

    /// How far a swipe has travelled before it counts as a card.
    ///
    /// Twelve points was too eager: a trackpad flicks a long way in a
    /// fraction of a second, so a small gesture crossed the threshold in a
    /// couple of events and the line ran away under the pointer. Sixty means
    /// a flick moves one card and a slow drag walks along the line, which is
    /// the difference between reaching something and overshooting it.
    private static let panThreshold: CGFloat = 60

    /// How much a mouse's wheel has to travel for one card.
    ///
    /// Two notches, and it was one notch first. The one-notch version was
    /// measured rather than guessed — a wheel reports a tenth of a point per
    /// notch — but right is not the same as right for the hand: a card is a
    /// thing being looked at, and one notch per card means every card on the
    /// line is three or four notches away, which is a lot of turning between
    /// one card and the next. Two notches puts a card every third notch, so
    /// the line still moves when the wheel is turned with one finger without
    /// arriving somewhere new at every notch.
    private static let wheelThreshold: CGFloat = 0.2

    /// How far one wheel event is allowed to move the line.
    ///
    /// A wheel turned hard does not arrive as more events, it arrives as one
    /// event carrying many notches — measured at up to thirty in a row, which
    /// would throw away most of the line before it could be read. Capped so a
    /// hard turn pages several cards rather than most of them.
    private static let wheelCardsPerEvent = 3

    /// How much travel may be kept over after an event was capped.
    ///
    /// Some, so the rest of a hard turn arrives with the events that follow
    /// rather than being lost — but only some. Keeping all of it was the
    /// version before this: a fast turn left fifteen points on the
    /// accumulator, which is a hundred and fifty notches, and every notch
    /// after that spent itself quietly paging against an end it could not
    /// move. It read as "the wheel stops working once the line is at an end,
    /// and only if I reverse first" — the reason being a leftover, not the
    /// end. A hard turn is a burst of a few cards; more travel than that is
    /// not a turn that wants following, it is one that overran.
    private static let wheelCarryOver: CGFloat = 3

    /// How far a swipe has travelled before it counts as a card, so one flick
    /// moves the line a step rather than jumping to the far end.
    private var panAccumulator: CGFloat = 0

    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        // Two different questions, and conflating them was why the
        // suppression below used to clear itself too early. `inMenuBar` is
        // about the menu that is open right now: the pointer is somewhere in
        // the bar, so whatever it was reaching for is a menu and the line
        // has to wait. `inTrigger` is about the gesture: the pointer is
        // resting in the notch, which is what brings the line down. The notch
        // is inside the bar, so the first does not imply the second — but
        // the pointer has to be able to leave the bar without passing
        // through the notch, or the suppression would never clear.
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, TriggerBand.menuBar(of: $0), false) } ?? false
        let inTrigger = screenUnderPointer.map { TriggerBand.contains(mouse, on: $0) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the notch brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            // Each condition that can refuse the gesture is logged at most
            // once a second while the pointer rests there, so a notch that
            // will not open says which of the four doors is shut.
            if inTrigger, now.timeIntervalSince(lastTriggerLog) >= 1 {
                lastTriggerLog = now
                let blocked = screenUnderPointer.map { FullScreen.blocksLine(on: $0) } ?? true
                diagLog("Notch rest: opens=\(Self.opensFromNotch) suppressed=\(self.menuBarSuppressed) blocked=\(blocked) revealed=\(self.isRevealed)")
            }
            if Self.opensFromNotch, let screen = screenUnderPointer, inTrigger, !menuBarSuppressed,
               !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    // The gesture picks the deck: the left half of the notch
                    // is the clipboard, the right half the notes, and the
                    // flip key swaps whichever half the pointer found. Setting
                    // the deck does the rest — the pan, the search, the
                    // remembering are its own.
                    let deck = DropDeck.at(mouse, on: screen)
                    if line.deck != deck {
                        line.deck = deck
                        // The depth follows the deck. The subscription does
                        // this too, a runloop turn later; this one is here
                        // so the cards never draw into a panel still wearing
                        // the other deck's depth.
                        panel.placeOnScreen()
                    }
                    // The gesture is the wanting. `wanted` false is how the
                    // app says "nobody has asked for the line" — and the
                    // pointer resting in the notch is somebody asking. An
                    // emptied line kept `wanted` false and the notch mute,
                    // which is why clearing the cards killed the one gesture
                    // that could call them back.
                    wanted = true
                    refresh()
                    reveal()
                    diagLog("Notch brought the line down on \(screen.localizedName), deck \(String(describing: self.line.deck))")
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        // And a little below it. The zone was exactly the panel, so the
        // pointer standing a point under the pill — which is where it is
        // whenever the pill is short enough that the hand reaches past its
        // bottom edge, and it is a short pill whenever the search is shut —
        // counted as having left the line. Fifty points is not enough to
        // wander off while looking; it is exactly the distance from the pill
        // to where the hand rests when it is on the pill's last control.
        zone.origin.y -= 50
        zone.size.height += 50
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        // A propped line does not retract: it waits for a release, not for the
        // pointer to wander off. `busy` is the set of reasons the line should
        // hold where it is, and propped is the strongest of them.
        let busy = pinned || propped || GrabView.isDragging || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    ///
    /// The pager is the exception: its arrows are the one direct way to reach
    /// a card further back, so the pointer standing over it counts as over
    /// the line.
    ///
    /// The search is the other exception, and it is the opposite one. With the
    /// field open, the pill is two windows: the panel and, over the input half
    /// of it, the search window — the only one of the two that can take a
    /// key. So the panel lets go over the field and keeps hold everywhere else
    /// on the pill, or a click on the field arrives here and the caret never
    /// appears. The panel is below the search window, so letting go is enough:
    /// the press falls through to it rather than through both.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        let overField = SearchController.shared.isOpen && SearchController.shared.isOverField(flipped)
        // The plus that writes a new note, in the gap the rope's dip leaves.
        // A little room around it, for the same reason the photo has: a mark
        // this small with a target exactly its size is a target the hand
        // misses.
        let overPlus = line.plusRect.insetBy(dx: -3, dy: -3).contains(flipped)

        // A wider mouth on the way out than on the way in.
        //
        // The rectangle the pill reports is a few points off where the pill is
        // drawn, so a pointer resting on one spot reads as inside on one pass
        // and outside on the next. That reads as nothing until you know what
        // the panel does with the answer: letting go of the mouse is what
        // makes the material it is made of stop being hovered, so every flip
        // redraws the glass — light, dark, light, dark, thirty times a second,
        // with the hand not even moving.
        //
        // So a pointer that has arrived stays arrived until it is clearly
        // gone. The threshold is not a fix for the offset, it is a fix for
        // caring about the offset: nothing downstream needs to distinguish
        // nine points from zero, and the strip stops flickering whether the
        // two coordinate spaces ever agree or not.
        let onPill = pointerOnPill
            ? overPager(flipped, slack: 16)
            : overPager(flipped, slack: 3)
        pointerOnPill = onPill

        // The search window is above this one and does its own hit testing,
        // so while the field is open this panel has to stay out of its way —
        // but only over the field, since the cross that closes it is still
        // drawn here.
        let passThrough = overField || (!overPhoto && !onPill && !overPlus)
        // Written only when it changes. Setting it to the value it already has
        // is not free: the window is told to reconsider every mouse event on
        // the screen, which is the same redraw the flip above causes.
        if panel.ignoresMouseEvents != passThrough {
            panel.ignoresMouseEvents = passThrough
        }
        line.panelFrame = panel.frame
    }

    /// Keeps the menu's ticks in step with the filter, so choosing one from
    /// the line and opening the menu again shows where it ended up.
    private func updateFilterItems() {
        guard let filterMenu = filterMenuRef,
              let filterTitle = filterMenu.supermenu?.items.first(where: { $0.title == L("What the clipboard shows") }) else { return }
        for item in filterMenu.items {
            if let option = Line.Filter.allCases.first(where: { $0.label == item.title }) {
                item.state = line.showing == option ? .on : .off
            }
        }
    }

    /// Space opens the card under the pointer at size.
    ///
    /// A monitor rather than a key handler in the card, because the panel
    /// cannot become key and never receives a key event: it is a strip that
    /// floats over everything and takes no focus. A local monitor sees the
    /// key and this is the app it went to, which is the app the user typed
    /// into — so the space belongs to the line, not to the line's window.
    ///
    /// Only when the pointer is over a card, and only while the line is down.
    /// The two doors that act on a line already down: write a note, keep the
    /// rope down.
    ///
    /// They are bare letters, and a bare letter is only safe to answer in one
    /// place. The first attempt reached for a global key-down monitor — which
    /// reads silently as nothing at all, because a global *key* monitor is one
    /// of the events the system only delivers to an app the user has trusted
    /// with Input Monitoring, and an untrusted app's handler simply never
    /// fires. The answer that needs no permission is the same Carbon
    /// registration the summons use, held only while it can be answered
    /// honestly: registered while the line is down, unregistered the moment
    /// it goes back up. While it is registered the letter is taken here
    /// rather than leaking into the app behind; while it is not, the letter
    /// belongs to whatever the user is typing in.
    ///
    /// Where the pointer is deliberately plays no part. It used to: the doors
    /// were registered only while the pointer was inside the panel's height,
    /// which kept the bare letter out of the app behind for as long as the
    /// hand was elsewhere — but it also meant the lock answered only with the
    /// pointer already on the rope, the one place it is least needed, since
    /// the rope itself is right there to click. So while the line is down the
    /// letter is taken wherever the pointer happens to be, and the price is
    /// that the letter is unavailable to whatever is being typed in for as
    /// long as the line is down.
    ///
    /// Registration still waits while this app is the frontmost one, because
    /// the two places the user types *into this app* — the search field over
    /// the pill and the note being written — would otherwise be eaten by the
    /// very hot key that answers beside them.
    ///
    /// The line going down or up is announced by `setRevealed`, which is why
    /// only the frontmost-ness is observed here.
    private func watchFrontmost() {
        let changed: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePanelKeys() }
        }
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil,
                                                   queue: .main, using: changed)
        }
    }

    /// Registers and unregisters the panel doors to match the two states they
    /// can be answered in: the line is down, and this app is not the frontmost
    /// one. Called on each of those two changes, so it has to be cheap when
    /// nothing changed.
    private func updatePanelKeys() {
        guard isRevealed, !NSApp.isActive else {
            if !panelKeys.isEmpty {
                diagLog("Hotkey panel disarmed: revealed=\(isRevealed) appActive=\(NSApp.isActive)")
                panelKeys = [:]
            }
            // The space key answers to the same two conditions the panel
            // doors do, and a change here can end an arming with no mouse
            // move to announce it — the line going up under a resting
            // pointer, most commonly.
            updateSpaceKey()
            return
        }
        updateSpaceKey()
        for door in Door.panelDoors {
            guard door.isSet else { panelKeys[door] = nil; continue }
            guard panelKeys[door] == nil else { continue }
            let key = HotKey(keyCode: door.keyCode,
                             modifiers: door.carbonModifiers,
                             id: door == .note ? 3 : 4) { [weak self] in
                diagLog("Hotkey fired: \(door.rawValue)")
                switch door {
                case .note: NoteController.shared.beginNew()
                case .prop: self?.toggleProp()
                default: break
                }
            }
            panelKeys[door] = key
            reportRegistration("panel \(door.rawValue)", key)
        }
    }

    private func watchZoomKey() {
        /// The key that opens a card at size, and the same key puts it away.
        ///
        /// Command-return rather than space, and the choice is forced by the
        /// architecture rather than made: the panel is a strip over the top of
        /// the screen that cannot take focus, so it is never the app a key is
        /// delivered to, and the only kind of monitor that hears a key pressed
        /// somewhere else cannot take it back. Space therefore arrived in the
        /// app behind as well — a space where you were typing, and a preview
        /// of the card you meant to read appearing twice if that app has its
        /// own idea of what space does.
        ///
        /// Command-return has no meaning in the apps this is used with, and
        /// a command key is not something a text field eats by accident.
        /// (Space itself is answered too now, but on its own terms — see
        /// `watchSpacePreview`, which arms it only while it can be swallowed.)
        let open: (NSEvent) -> Void = { [weak self] event in
            // The guard lives here, on the global path, and must never move:
            // this monitor hears every key every other app receives — the
            // user's typing, and the ⌘V this app itself synthesizes for a
            // double-click paste. Unguarded, a double-click on a card would
            // open its own preview 0.25s later (the paste keystroke arriving
            // with the pointer still on the card), and any key typed while
            // hovering a card would toggle it. Regression shipped in 1.7.0
            // and caught the same evening: the double-click paste came out
            // wearing a preview.
            guard event.keyCode == 36, event.modifierFlags.contains(.command) else { return }
            MainActor.assumeIsolated { self?.toggleHoveredZoom() }
        }
        // Returning nil would swallow the key, and a global monitor cannot: the
        // command-return still goes to the app behind. That is the trade for
        // using one, and a command nothing else means is a small thing to
        // arrive at.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            open(event)
        }) {
            zoomKeyMonitor = global
        }
        // A local one as well, for when this app somehow is the one with the
        // key: a panel that cannot become key normally never is, but a future
        // change could make it so and the zoom should not depend on that.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 36 && event.modifierFlags.contains(.command) {
                MainActor.assumeIsolated {
                    self?.toggleHoveredZoom()
                }
                return nil
            }
            return event
        }) {
            zoomLocalMonitor = local
        }
        // Escape closes, wherever it is pressed. With a propped line it lets the
        // rope go first — the one gesture that releases it without reaching
        // for the peg or the menu — and with the zoom up it dismisses that. It
        // is a key the user reaches for on purpose and rarely by accident, so
        // answering it from anywhere is the simpler, expected reading: the
        // rope that was propped down is let go by the same key wherever the
        // hand happens to be, which is what the keyboard-only path wants — pin
        // from anywhere with a shortcut, release from anywhere with Esc.
        if let dismiss = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.propped { self.toggleProp(); return }
                ZoomController.shared.dismiss()
            }
        }) {
            zoomDismissMonitor = dismiss
        }
    }

    /// Previews whichever card the pointer is over, or closes that preview.
    ///
    /// The one gesture ⌘↩ and the space key both mean, so the one body
    /// answers both and neither can drift. Notes read here too — a note's
    /// plain text in the reader, the same words a paste of it carries —
    /// which is the reading half of the 2026-10-17 unification; the editing
    /// half belongs to the corner mark, the long press and the menu.
    private func toggleHoveredZoom() {
        guard isRevealed,
              let id = hoveredCardID(),
              // Either deck: a note hovers on the notes deck, where the card
              // is in `notes` and an `items` lookup made space say nothing.
              let item = line.onLine.first(where: { $0.id == id }) else { return }
        // A file has nothing to enlarge: it is read by the system.
        if case .file(let urls) = item.payload {
            if urls.count == 1 { NSWorkspace.shared.open(urls[0]) }
            else { line.copy(id) }
            return
        }
        guard let frame = cardFrame(for: id) else { return }
        ZoomController.shared.toggle(item, at: NSPoint(x: frame.midX, y: frame.minY),
                                     on: panel.screen)
    }

    /// The space key, on Quick Look's terms.
    ///
    /// The reason ⌘↩ exists at all is that a global key monitor hears a space
    /// pressed elsewhere but cannot swallow it, so the space leaked into the
    /// app behind. But that is a fact about *monitors*, not about the key:
    /// the Carbon hot key registration the panel doors use does swallow, and
    /// the panel doors already showed the shape of an honest answer — hold
    /// the key only while it can be taken without stealing. Their condition
    /// is "the line is down and this app is not frontmost"; space tightens it
    /// with the pointer, which is exactly the sense Quick Look gives the key:
    /// the hovered card is the selected one.
    ///
    /// So the space key is registered only while the pointer sits on a card
    /// that a space can answer, and unregistered the moment that stops being
    /// true. While it is armed the hand is up on the line, not behind the
    /// keyboard — nothing is being typed into for a space to be taken from.
    /// Notes answer it too now: their plain text reads in the zoom, which is
    /// the reading half of the 2026-10-17 unification.
    private func watchSpacePreview() {
        let moved: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSpaceKey() }
        }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: moved) {
            spaceMoveMonitor = global
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            moved(event)
            return event
        }) {
            spaceLocalMoveMonitor = local
        }
        // This app frontmost is the one state the Carbon key must not cover —
        // armed there it would eat the spaces typed into the search field and
        // the note editor. The local monitor answers instead, swallowing only
        // when the pointer is on a card and nothing here is taking text.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return event }
            var swallow = false
            MainActor.assumeIsolated {
                guard let self, self.isRevealed, NSApp.isActive else { return }
                // The two places this app is typed into: a field editor
                // (the search field over the pill, the note being written)
                // arrives as an `NSTextView`.
                if let first = NSApp.keyWindow?.firstResponder,
                   first is NSTextView || first is NSTextField { return }
                guard let id = self.hoveredCardID(),
                      let item = self.line.items.first(where: { $0.id == id })
                else { return }
                self.toggleHoveredZoom()
                swallow = true
            }
            return swallow ? nil : event
        }) {
            spaceLocalKeyMonitor = local
        }
    }

    /// Arms or disarms the space hot key to match the moment.
    ///
    /// Called on every mouse move while the line is down — a question of one
    /// rectangle test — and on the two changes that can end an arming without
    /// a move: the line going up, and this app becoming frontmost. Cheap when
    /// nothing changed, which is nearly always.
    private func updateSpaceKey() {
        // Any hovered card qualifies: notes read in the zoom as their plain
        // text, files open, everything else presents.
        let eligible = isRevealed && !NSApp.isActive && hoveredCardID() != nil
        if eligible {
            guard spaceHotKey == nil else { return }
            let key = HotKey(keyCode: 49, modifiers: 0, id: 5) { [weak self] in
                MainActor.assumeIsolated { self?.toggleHoveredZoom() }
            }
            spaceHotKey = key
            diagLog("Space preview armed: install=\(key.installStatus) register=\(key.registerStatus)")
        } else if spaceHotKey != nil {
            // Releasing the instance unregisters it — each `HotKey` takes its
            // own registration with it.
            spaceHotKey = nil
            diagLog("Space preview disarmed")
        }
    }

    /// The card the pointer is over, if any.
    ///
    /// The hit rectangles come from SwiftUI, whose global space has its
    /// origin at the top left; AppKit puts the mouse's at the bottom left.
    /// Converting between them needs the panel's height, and getting that
    /// wrong puts every card on the opposite side of the screen from where it
    /// hangs — which reads as "the click went through" rather than as a
    /// mistake in arithmetic.
    private func hoveredCardID() -> UUID? {
        let mouse = NSEvent.mouseLocation
        let local = panel.convertPoint(fromScreen: mouse)
        let swiftUI = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.first { $0.value.insetBy(dx: -4, dy: -4).contains(swiftUI) }?.key
    }



    /// Where the pill sits, so the pointer over it keeps the panel awake.
    ///
    /// From the rectangle the pill reports about itself.
    ///
    /// This is the test that decides whether a press reaches the pill at all:
    /// the panel lets clicks through to whatever is underneath, and only stops
    /// doing so while the pointer is on something that belongs to it.
    ///
    /// `slack` is how far outside the rectangle still counts as on it. Two
    /// values are asked for rather than one, because a single value makes the
    /// answer flip either side of it — see `pointerOnPill`.
    private func overPager(_ point: CGPoint, slack: CGFloat) -> Bool {
        let rect = line.pagerRect
        guard rect != .zero else { return false }
        return rect.insetBy(dx: -slack, dy: -slack).contains(point)
    }

    /// What the pointer is doing to the pill, once a second while it is out.
    ///
    /// A pill that changes width while the pointer is standing still is the
    /// case this is for: the rectangle the pill reports about itself is read
    /// by the tick below to decide whether the pointer is still over the
    /// line, and a rectangle that is being animated through three hundred
    /// points of width is a rectangle that will say "no" on some frame of the
    /// animation.



    /// How many cards the screen has room for, worked out the same way
    /// `LineView` does it, so the two agree on when there is more to show.
    var pagerRoom: Int {
        max(1, Int((panel.frame.width - 200) / Layout.pitch(for: line.deck)) + 1)
    }

    /// Registers both summon doors from the settings' answer, and refreshes
    /// the two panel doors. Called at launch and again whenever a recorder
    /// hands in a new combination — the old keys unregister as their
    /// instances go, so a re-registration is a clean swap rather than a
    /// second registration stacked on the first.
    func registerHotkeys() {
        // Let go of everything held before anything new is registered.
        //
        // Carbon refuses a combination that is already registered — by
        // another app, and equally by this one. The old instances used to be
        // released only as the new ones were being assigned, which put the
        // new registration *before* the old unregistration, so re-recording
        // the combination a door already had was refused with
        // `eventHotKeyExistsErr` and then immediately unregistered anyway:
        // the key was left held by nobody while the recorder's pill went on
        // showing it, which is exactly a shortcut that has stopped working.
        // Emptying the slots first makes the swap clean for every
        // combination, the one a door already had included.
        clipboardKey = nil
        notesKey = nil
        panelKeys = [:]

        // Only the two summons are permanent. The doors that act on a line
        // already down are bare letters, and a bare letter registered for
        // good would take that letter out of every app on the machine — they
        // are registered and unregistered instead as the pointer comes and
        // goes, see `updatePanelKeys`.
        //
        // A door with no key is not registered at all. Carbon is asked for a
        // real key code and nothing else, and a -1 handed to it is not a
        // refusal the API can give — it is a trap that takes the app down on
        // the spot, which is how a cleared door once quit the program. So the
        // unset door simply holds no key instance.
        if Door.clipboard.isSet {
            let key = HotKey(keyCode: Door.clipboard.keyCode,
                             modifiers: Door.clipboard.carbonModifiers, id: 1) { [weak self] in
                diagLog("Hotkey fired: clipboard")
                self?.showDeck(.clipboard)
            }
            clipboardKey = key
            reportRegistration("clipboard", key)
        }
        if Door.notes.isSet {
            let key = HotKey(keyCode: Door.notes.keyCode,
                             modifiers: Door.notes.carbonModifiers, id: 2) { [weak self] in
                diagLog("Hotkey fired: notes")
                self?.showDeck(.notes)
            }
            notesKey = key
            reportRegistration("notes", key)
        }
        // Let this re-arm whichever panel doors still hold a key, now that
        // the old ones are a moment gone.
        updatePanelKeys()
    }

    /// One line about what Carbon answered for a key, in the diagnostics log.
    ///
    /// Worth logging rather than trusting: a refused registration is a
    /// shortcut that is silently dead — the settings still show the
    /// combination and the menu still advertises it — and the only way a
    /// report of "the shortcut does nothing" is ever going to be answered is
    /// if the answer Carbon gave is written down somewhere.
    private func reportRegistration(_ name: String, _ key: HotKey) {
        let refused = key.registerStatus == OSStatus(-9878)
        diagLog("Hotkey \(name): code=\(key.keyCode) mods=\(key.modifiers) install=\(key.installStatus) register=\(key.registerStatus)\(refused ? " (refused: already held by something else)" : "")")
    }

    /// The settings' way in. The recorder knows a combination changed; the
    /// application is the one that owns the keys.
    static func reregisterHotkeys() {
        (NSApp.delegate as? AppDelegate)?.registerHotkeys()
    }

    private func updateCapacity() {
        // Nothing is thrown away while the app is running. What the line
        // shows is what fits on the screen, worked out by `LineView.fits`
        // for itself, and what is kept behind it is decided by the retention
        // window at launch — see `Line.restore`. There is no cap to set here
        // any more, and there never was one that did anything: the property
        // this used to write was read by nothing, so the history grew without
        // bound while a constant claimed otherwise.
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The board fills in while copied content is hung, so it shows at a
    /// glance that the clipboard is being watched.
    private func updateStatusIcon() {
        // Guarded: setClipboard can reach this before setUpStatusItem has run
        // now that the item is hung a beat after launch.
        guard let button = statusItem?.button else { return }
        let on = ClipboardWatcher.isEnabled
        let description = on ? L("Clothespeg, hanging what you copy") : "Clothespeg"
        let name = on ? "list.clipboard.fill" : "list.clipboard"
        // An explicit point size: without it the menu-bar button can size the
        // template to zero width and the icon never paints, even though the
        // image itself is valid (a classic status-bar-from-SF-Symbol trap).
        let base = NSImage(systemSymbolName: name, accessibilityDescription: description)
        // 14, not 18: this symbol runs tall for its point size (18 drew 19×25),
        // which read as oversized beside the neighbours' ~16pt glyphs.
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .medium)
        // withSymbolConfiguration is optional: if it ever fails, keep the
        // base symbol rather than handing the button a nil image and showing
        // nothing.
        let image = base?.withSymbolConfiguration(config) ?? base
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The inbox's tick is only ever looked at here, so this is where the
        // answer is read: a location the user moved in ⌘⇧5 turns the tick
        // off the moment the menu opens, whatever the guard timer last knew.
        if Inbox.screenshotInboxEnabled, Inbox.locationMovedAway() {
            setScreenshotInbox(false)
        }
        menu.removeAllItems()

        // Two doors, each named by the rope it opens and carrying the key
        // that opens it: ⌃⌥C for the clipboard's, ⌃⌥N for the notes'. A door
        // already open closes on a second press. A door is named by what is
        // behind it, not by where you are standing, so the titles do not
        // change with the deck.
        let clipboardItem = ClosureMenuItem(L("Open the clipboard")) { [weak self] in
            self?.showDeck(.clipboard)
        }
        clipboardItem.keyEquivalent = Door.clipboard.displayCharacter.lowercased()
        clipboardItem.keyEquivalentModifierMask = Door.clipboard.nsModifiers
        menu.addItem(clipboardItem)

        let notesDoor = ClosureMenuItem(L("Open the notes")) { [weak self] in
            self?.showDeck(.notes)
        }
        notesDoor.keyEquivalent = Door.notes.displayCharacter.lowercased()
        notesDoor.keyEquivalentModifierMask = Door.notes.nsModifiers
        notesDoor.toolTip = L("The notes hang on the same line as what you copy")
        menu.addItem(notesDoor)

        // The rope, propped down so it stays until released. The same toggle
        // the peg at the end of the rope offers, here for the times the line is
        // not on screen to click — keeping it from being a control only the
        // rope knows about. A check marks the propped state.
        //
        // Named for the rope it acts on rather than left as a bare "Lock": the
        // line shows one of the two ropes at a time and this acts on whichever
        // one that is, so the object "lock" was missing is exactly the thing
        // worth saying out loud. Which rope that is is the deck the line is
        // showing, and the menu is rebuilt on every open — so the name is
        // never out of date, and never has to be guessed at from the last
        // time a rope came down.
        let rope = line.deck == .notes ? L("Lock the notes rope") : L("Lock the clipboard rope")
        let prop = ClosureMenuItem(rope) { [weak self] in
            self?.toggleProp()
        }
        prop.state = propped ? .on : .off
        prop.toolTip = L("Locks the rope the line is showing — the clipboard's or the notes' — and keeps it on screen. Choose again to let it go")
        menu.addItem(prop)

        // A note, in the window a note is written in. The line itself is the
        // door for writing now — the plus above the notes' rope — and the
        // menu keeps a copy of it for the times the line is not on screen.
        menu.addItem(ClosureMenuItem(L("New note")) { [weak self] in
            self?.newNote()
        })

        // The clipboard's own block, one group and one idea: the watching,
        // the seeing, the showing and the folder it all lands in.
        menu.addItem(.separator())
        // Named for what it does rather than for the paper it used to
        // imagine: the watching is the whole of the feature, and the line
        // is where what is watched ends up.
        let clipboard = ClosureMenuItem(L("Monitor the clipboard")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Anything you copy hangs on the line")
        menu.addItem(clipboard)

        // The screenshot inbox, marked like the watching above: a tick is how
        // this menu says "on". Off until asked for, because turning it on
        // moves where macOS saves screenshots system-wide — the previous
        // place is put back when the tick goes away or the app quits.
        let inbox = ClosureMenuItem(L("Hang new screenshots")) { [weak self] in
            self?.setScreenshotInbox(!Inbox.screenshotInboxEnabled)
        }
        inbox.state = Inbox.screenshotInboxEnabled ? .on : .off
        inbox.toolTip = L("When on, screenshots hang at once instead of piling up on the Desktop (or the folder you changed them to); the previous save location is put back when this is off or the app quits")
#if !APPSTORE_LITE
        menu.addItem(inbox)
#endif

        // Whether a copy keeps the formatting it arrived with. Read from the
        // same switch the settings page writes, so the two cannot disagree,
        // and marked like the watching above: a tick is how this menu says
        // "on".
        let formatted = ClosureMenuItem(L("Copy with formatting")) {
            FormatCopy.isEnabled.toggle()
        }
        formatted.state = FormatCopy.isEnabled ? .on : .off
        formatted.toolTip = L("When on, a card copied or pasted keeps the formatting it was copied with")
        menu.addItem(formatted)

        // The grey cards whose file has gone, all down at one ask. Offered
        // only when there is something to offer: a menu item that answers
        // "nothing to do" is one more word for nothing. Read here rather
        // than carried, because the menu is rebuilt on every open, so the
        // answer is as fresh as the menu is.
        let missing = line.items.contains { item in
            guard !item.falling, !item.payload.files.isEmpty else { return false }
            return item.payload.files.contains { !FileManager.default.fileExists(atPath: $0.path) }
        }
        let discardMissing = ClosureMenuItem(L("Discard missing files")) { [weak self] in
            self?.line.discardMissing()
        }
        discardMissing.isEnabled = missing
        discardMissing.toolTip = L("Cards whose file has been deleted or moved away come down at once")
        menu.addItem(discardMissing)

        // The filter is here as well as on the line: the line is only visible
        // while it is down, and a filter that can only be seen and changed
        // while something is up is one that gets forgotten.
        //
        // Named for the only rope it answers to — a filter narrows what the
        // clipboard shows, and a note has no kind to narrow by — and always
        // on, because the graying was keyed to whichever deck hung last,
        // which is a state the menu has no business remembering. Choosing a
        // filter opens the clipboard: it is the one thing a filter can look
        // at, so the choice carries its own door.
        let filterTitle = NSMenuItem(title: L("What the clipboard shows"), action: nil, keyEquivalent: "")
        let filterMenu = NSMenu()
        for option in Line.Filter.allCases {
            let item = ClosureMenuItem(option.label) { [weak self] in
                guard let self else { return }
                line.showing = option
                updateFilterItems()
                if line.deck != .clipboard || !isRevealed {
                    line.deck = .clipboard
                    openPinned()
                }
            }
            item.state = line.showing == option ? .on : .off
            filterMenu.addItem(item)
        }
        filterTitle.submenu = filterMenu
        filterMenuRef = filterMenu
        menu.addItem(filterTitle)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests in the notch")) {
            AppDelegate.opensFromNotch.toggle()
        }
        hover.state = Self.opensFromNotch ? .on : .off
        hover.toolTip = TriggerBand.hasNotch
            ? L("Push the pointer up against the notch to bring the line down")
            : L("Rest the pointer in the menu bar to bring the line down")
        options.addItem(hover)
        // Named for the only deck it answers to: copies arrive by
        // themselves and notes do not, so this is a fact about the
        // clipboard's rope and the title says which one.
        let peek = ClosureMenuItem(L("When something new is copied")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
#if !APPSTORE_LITE
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
#endif
        bringDown.submenu = options
        menu.addItem(bringDown)

        menu.addItem(.separator())
        // Last, where a settings item belongs — the things above it are
        // things to do and this is the one place that is not. The taste
        // questions the menu used to carry — the swipe direction, the sounds,
        // the login — live in the settings now, where a choice made once
        // belongs.
        menu.addItem(ClosureMenuItem(L("Settings…"), key: ",") {
            SettingsController.shared.open()
        })
        menu.addItem(ClosureMenuItem(L("Quit Clothespeg"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// Whether the notes should go, asked before they do.
    ///
    /// An alert rather than a second menu item, because there is nothing to
    /// undo and nowhere to recover from: `Notes.json` is every copy of a note
    /// there is. So the wording says what is being lost rather than asking
    /// whether the user is sure — a question about being sure is one nobody
    /// can answer about a thing they cannot see.
    private func confirmTakingNotesDown() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Clear every note?")
        alert.informativeText = L("The notes are kept nowhere else, so this cannot be undone.")
        alert.addButton(withTitle: L("Clear them"))
        alert.addButton(withTitle: L("Keep them"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Clothespeg to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
