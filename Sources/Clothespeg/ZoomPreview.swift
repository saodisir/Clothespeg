import SwiftUI
import AppKit
import Quartz
import QuickLookUI

/// Reading a card properly, without changing the line.
///
/// A card is 150pt wide because a screen fits eleven of them. That is the
/// right size for a picture and the wrong one for a snippet: a line of code
/// at 10pt is thirty-odd characters, and the difference between the first
/// card and the fifth is often a bracket.
///
/// The zoom is a separate window rather than a bigger card, deliberately.
/// Making the card itself grow would push its neighbours along the line,
/// and the whole point is that the line stays where it was while one card is
/// read. It is also the only way to show more without the line rearranging
/// under the pointer.
struct ZoomPreview {
    /// Where it is showing, and what the user was looking at.
    var payload: Payload
    var origin: Origin
    /// Below the card that opened it, in that card's own coordinates.
    var anchor: NSPoint
    /// What a code in the picture says, when it holds one. Nil for every
    /// card that is not a picture holding a code, which is nearly all of
    /// them.
    var qrcodes: [String]?

    /// One size for every kind of card.
    ///
    /// The window is the same whatever is in it, so the reader learns where
    /// to look and a window that changes shape between a note and a picture
    /// reads as two different things rather than the same one. Roughly four
    /// times a card in each direction: enough for a screenshot to be read at
    /// its own resolution and for a line of code to lose its truncation, and
    /// small enough to stay on the screen with room around it.
    static let size = CGSize(width: 640, height: 440)

    /// Kept for the callers that want to know it without the type; the size
    /// is the same either way.
    var size: CGSize { Self.size }
}

/// The window the zoom opens in.
///
/// A borderless panel that takes no focus: pressing space again, or
/// clicking anywhere, dismisses it, and the app the user was in never
/// changes. A reader that stole the key window would need a second click
/// to get back to work, which is worse than the small card was.
///
/// It does take the mouse, and that is a change worth recording. The first
/// version took nothing at all — `ignoresMouseEvents = true` — which made
/// every click here a dismiss and looked like the simplest possible reader.
/// What it also did was hand the wheel to the app underneath: scroll events
/// are delivered by hit testing, and a window that refuses the mouse is not
/// in the hit test, so a long snippet opened at size could not be scrolled
/// by a trackpad or by the scroll bar that was drawn down its right side.
/// Reading a long thing is the whole reason this window exists, so it takes
/// the mouse and pays for it by telling a click from a drag: a press that
/// moved is a scroll bar being dragged or a selection being made, and a press
/// that did not is still a click, which still dismisses.
final class ZoomWindow: NSPanel {
    /// What a press means once it is known to have been a press rather than
    /// the beginning of a drag.
    var onPress: (() -> Void)?
    /// Where the current press started, in window coordinates. Nil between
    /// presses, and the distance from here is what tells the two apart.
    private var pressedAt: NSPoint?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Whether a release is a click, decided by how far the press travelled.
    ///
    /// Three points, which is the same order as the slop AppKit uses to call
    /// a press a drag: enough that a hand resting on a trackpad while it
    /// rolls does not turn a scroll into a dismiss, and small enough that a
    /// deliberate click never reads as a drag.
    private static let clickSlop: CGFloat = 3

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressedAt = event.locationInWindow
        case .leftMouseUp:
            let origin = pressedAt
            pressedAt = nil
            if let origin,
               hypot(event.locationInWindow.x - origin.x,
                     event.locationInWindow.y - origin.y) < Self.clickSlop {
                // Out of this call rather than inside it: the press and the
                // release are still being delivered to the scroll view, and
                // taking the window away mid-delivery is the sort of thing
                // that works until the day it does not.
                DispatchQueue.main.async { [weak self] in self?.onPress?() }
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Placed under the card that opened it, kept on screen rather than
    /// allowed to hang off the edge of it.
    func place(under anchor: NSPoint, on screen: NSScreen?, content: CGSize) {
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(anchor.x - content.width / 2, visible.minX + 12),
                    visible.maxX - content.width - 12)
        // Below the card, unless there is no room, in which case above it:
        // the zoom covers the card it belongs to, never the line above it.
        var y = anchor.y - content.height - 16
        if y < visible.minY + 12 { y = anchor.y + 22 }
        y = min(y, visible.maxY - content.height - 12)
        setFrame(NSRect(x: x, y: y, width: content.width, height: content.height), display: true)
    }
}

/// What the zoom window draws: the card at size, with the same paper and the
/// same glass, so a snippet read here is the snippet that is on the line.
private struct ZoomCard: View {
    let preview: ZoomPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preview.payload.isImage, let url = preview.payload.imageURL,
               let image = NSImage(contentsOf: url), image.size.width > 0 {
                // Aspect-fit inside the window, and centred: a screenshot
                // stretched to fill a fixed box is a lie about what it shows.
                // A very tall or very wide one is a different lie the other
                // way — filling to the width and scrolling for the height —
                // so the aspect fit is the one that never distorts, and the
                // window is the size the picture needs up to a limit.
                //
                // A picture holding a code gets a strip under it saying what
                // the code says. Under rather than over: the picture is still
                // the thing being looked at, and the code is what it turned
                // out to hold. A picture holding nothing keeps the whole
                // window, exactly as it had before any of this existed.
                VStack(spacing: 0) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let text = preview.qrcodes?.first {
                        CodeReading(text: text, isLink: QRCodes.link(in: text) != nil)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if preview.payload.files.count > 1 {
                // Several files are not a document, so there is nothing to
                // render. They are listed: the point of looking is to see
                // what is in the pile before dragging it somewhere, and one
                // file's preview would be a detail of a selection rather than
                // the selection.
                SeveralFiles(files: preview.payload.files)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = preview.payload.fileURL {
                // The system's own renderer, not a note about why there is
                // not one. Writing a renderer per format is a project the
                // size of Preview itself, and this is the view form of the
                // thing macOS has used for twenty years — it knows formats
                // this app has never heard of and will keep knowing them
                // after this stops compiling.
                //
                // It needs its framework linked by hand, and the properties
                // its documentation names are not the ones it has: a preview
                // item and a delegate, not a data source. That is written
                // down here because the next person to read the
                // documentation will get it wrong the same way.
                SystemPreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .note(let note) = preview.payload {
                // A note reads as its plain text, the same words a paste
                // carries — ticks spelled out. Editing happens elsewhere
                // (the corner mark, the long press, the menu); the reader
                // only shows, which is what a space asks of it.
                ReadingText(text: note.plainText, isCode: false)
            } else if case .text(let string, let isCode) = preview.payload {
                ReadingText(text: string, isCode: isCode)
            }
        }
        .frame(width: ZoomPreview.size.width, height: ZoomPreview.size.height)
        // Everything below is wrapped in one compositing group so the corner
        // radius is decided once, at the outside, and nothing drawn inside can
        // put a square edge back. Shadow is the other half: a shadow drawn
        // outside a clip is the shape of what casts it, and if the clip is
        // inside a group the shadow is drawn from the group's rectangle — a
        // soft square exactly the size of the window, whose four corners are
        // what has been showing round the card.
        // No shadow here. A shadow is drawn from the shape casting it and
        // SwiftUI has been drawing this one from a rectangle the size of the
        // window, which is the square that kept appearing around the card. The
        // window's own layer clips to the radius; a shadow would have to be
        // drawn outside the window to survive, which a panel this size has
        // no room for. The paper is drawn flat and the window's edge is the
        // only edge.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PayloadCard.paper)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
    }
}

/// The strip under a picture that held a code: what it says, and where to go
/// to do something with it.
///
/// No button, and not for want of trying. The zoom window does not take the
/// mouse at all — any click dismisses it — so a button drawn here would be a
/// control that cannot be pressed, which is worse than no control. The card's
/// right-click menu is where a code is copied or followed; this is where it is
/// read, and the hint says so rather than leaving the user to guess.
private struct CodeReading: View {
    let text: String
    let isLink: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    // Not selectable, though it is reading matter. The zoom
                    // window takes no mouse events at all — every click
                    // dismisses it — so a selection here would be a
                    // decoration: the pointer never reaches the text. Copying
                    // is the right-click menu's job, and the hint below says
                    // where it is.
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(isLink ? L("Right-click the card to open the link")
                            : L("Right-click the card to copy the contents"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A wash rather than a panel: it is part of the picture's window, not
        // a thing laid on top of it. Resolved from `primary` so it darkens in
        // the light and lightens in the dark, which is the same relationship
        // the paper and the glass already have.
        .background(Color.primary.opacity(0.055))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
    }
}

/// The reading half of a text or note zoom: the whole thing, scrolling
/// rather than truncating — the reason to open this is that the card cut the
/// text off, and a zoom that cut it off too would have solved nothing.
private struct ReadingText: View {
    let text: String
    let isCode: Bool

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(isCode ? .system(size: 13, design: .monospaced)
                             : .system(size: 14))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .scrollIndicators(.automatic)
    }
}

/// Owns the one zoom window there is, and the keys that open and close it.
@MainActor
final class ZoomController {
    static let shared = ZoomController()

    private var window: ZoomWindow?
    /// The card the zoom belongs to, so a second press on it closes rather
    /// than reopens, and a press on another card replaces it.
    private var showing: UUID?
    /// Every card on the line, so a press on a card can be answered without
    /// asking where the pointer is.
    private var registry: [UUID: Pegged] = [:]
    /// Where the zoom was last put, so a card whose contents change under it
    /// can be shown again in the place the user is already reading.
    private var lastAnchor: NSPoint?
    /// Keys is monitored rather than handled by the panel: the panel cannot
    /// become key, so it never receives a key event at all.
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var globalClick: Any?

    private init() {}

    /// Whether the zoom is showing this card, so the card can say so.
    func isShowing(_ id: UUID) -> Bool { showing == id }

    /// Whether the zoom is showing anything at all.
    ///
    /// Asked by the space key, which arms itself from "is the pointer on a
    /// card" — a question that stopped being the same one the moment this
    /// window took the mouse. With the pointer over the window it is over no
    /// card, and a key that disarmed there would leave a reader holding a
    /// page it cannot put down.
    var isShowingAny: Bool { showing != nil }



    /// Opens or closes a card's zoom from a press on the card itself.
    ///
    /// The card knows where it is and what it holds; this is told rather than
    /// asked, because the only thing it would ask for — which card is under
    /// the pointer — is a question about where the pointer is, and the press
    /// that arrived here has already answered it.
    func toggleZoom(id: UUID, anchor: NSPoint) {
        guard let item = lookup(id) else { return }
        if showing == id {
            dismiss()
            return
        }
        // Some things are somewhere you can go rather than something you read
        // at a size: a folder is a place to put files, a link is somewhere to
        // be taken. Those are acted on. Everything else — a document, an
        // archive, a picture, a line of text — is opened in a window, which
        // is where the system knows how to show it.
        //
        // An archive is a window and not an unpacking. Unpacking is a thing a
        // person asks for, on purpose, having looked at what is in it; a
        // click on a card is a request to look, and answering it by writing
        // files into a folder beside the thing is how a pile of rubbish
        // appears without anyone having decided to make one.
        switch item.payload {
        case .file(let urls):
            // One folder is somewhere to go. One file — and any number of
            // them, since several are a list to look at rather than a thing
            // to open — is something to look into, which is what the window
            // is for and the only place that can do it.
            if urls.count == 1 {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    NSWorkspace.shared.open(urls[0])
                    return
                }
            }
            present(item, at: anchor, on: anchorScreen(anchor))
        case .text(let string, _):
            // A link goes where it points. Everything else is text, and text
            // is read in the window like anything else.
            if let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
               PayloadCard.isLink(item.payload) {
                NSWorkspace.shared.open(url)
            } else {
                present(item, at: anchor, on: anchorScreen(anchor))
            }
        case .image:
            present(item, at: anchor, on: anchorScreen(anchor))
        case .note:
            // Never reached, and it has to be said here anyway. A note is the
            // one card whose content lives only in this app, so the press that
            // opens it goes to the editor rather than to a reader — the card
            // routes both the double click and the corner mark there, and the
            // zoom is never handed one. If that ever stops being true, the
            // right answer is an editor and not a window of uneditable text.
            break
        }
    }


    /// Hands the line over to the zoom, so a press on a magnifier can be
    /// answered from the card itself.
    func register(contentsOf items: [Pegged]) {
        registry = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }
    private func lookup(_ id: UUID) -> Pegged? { registry[id] }

    /// The card the zoom is showing has changed since it was opened — a code
    /// in it was read, and the window was already drawn.
    ///
    /// Shown again, in the same place, and only when it is the card already on
    /// screen: a code read for some other picture on the line has nothing to
    /// do with what the user is reading. This is the half-second between a
    /// card hanging and its code being known, where a space pressed in that
    /// half second would otherwise open a window that never learns.
    func refresh(_ item: Pegged) {
        guard showing == item.id, let anchor = lastAnchor else { return }
        present(item, at: anchor, on: anchorScreen(anchor))
    }

    /// The screen an anchor point is on, which is where the window goes.
    private func anchorScreen(_ anchor: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
    }

    func toggle(_ item: Pegged, at anchor: NSPoint, on screen: NSScreen?) {
        if showing == item.id {
            dismiss()
            return
        }
        present(item, at: anchor, on: screen)
    }

    private func present(_ item: Pegged, at anchor: NSPoint, on screen: NSScreen?) {
        let preview = ZoomPreview(payload: item.payload, origin: item.origin,
                                  anchor: anchor, qrcodes: item.qrcodes)
        let host = NSHostingView(rootView: ZoomCard(preview: preview))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        let panel = window ?? {
            let made = ZoomWindow(content: host)
            window = made
            return made
        }()
        // A second zoom reuses the window rather than making another, so
        // there is never more than one thing floating over the line.
        if panel.contentView !== host { panel.contentView = host }
        // The press that dismisses arrives at the window rather than at a
        // monitor: the window takes the mouse now, so a click inside it never
        // reaches `globalClick` below — that one only ever hears the events
        // going to *other* applications.
        panel.onPress = { [weak self] in self?.dismiss() }
        panel.place(under: anchor, on: screen ?? panel.screen, content: panel.frame.size)
        panel.orderFrontRegardless()
        showing = item.id
        lastAnchor = anchor
        watchForDismiss()
    }

    func dismiss() {
        window?.orderOut(nil)
        showing = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        globalClick = nil
    }

    /// Any click anywhere closes it, including a click on the card that
    /// opened it — the zoom is a reading pane, not a place to click.
    private func watchForDismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // escape
                MainActor.assumeIsolated { self?.dismiss() }
            }
            return event
        }
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }
}

/// The system's own renderer for a document, embedded.
///
/// `QLPreviewView` rather than `QLPreviewPanel`: the panel is the one that
/// looks like Finder's, and it wants the key window, which a strip over the
/// top of the screen cannot take. The view form has no such requirement.
///
/// The framework is linked by hand in Package.swift because SwiftPM does not
/// link it on its own, and the properties its documentation names are not the
/// ones it has — a preview item, not a data source. That is worth writing
/// down: the next person to read the documentation will get it wrong too.
struct SystemPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Compared by URL, so a second document is not reloaded on every
        // update and the scroll position is not thrown away under the reader.
        if (view.previewItem as? NSURL) != url as NSURL {
            view.previewItem = url as NSURL
        }
    }
}

/// The contents of a card holding several files: each one named, with its
/// icon, and the folder it is in when they do not share one.
///
/// A selection is worth reading before it is worth dragging. A path — which
/// is what a file preview shows for one file — says nothing about a pile of
/// them, and reading twenty paths is not something a person does.
private struct SeveralFiles: View {
    let files: [URL]

    /// Where they are, when they are not all in the same place.
    private var foldersDiffer: Bool {
        Set(files.map { $0.deletingLastPathComponent().path }).count > 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: icon(for: url))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if foldersDiffer {
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 14)
                    if url != files.last {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(PayloadCard.paper)
    }

    private func icon(for url: URL) -> NSImage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return NSWorkspace.shared.icon(for: .data)
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
