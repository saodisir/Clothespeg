import SwiftUI

/// One photo with its clothespin. All the charm lives here: it drops onto
/// the line, swings, sways with the breeze and falls when you pull it off.
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false
    /// How far down a note's paper has been scrolled, in points. Zero for
    /// every other kind of card, which has nothing to scroll.
    @State private var noteScroll: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }

    /// What holds a pinned card up: a pushpin, not a clothespin.
    ///
    /// The clothespin says "clipped on" — hanging until the rope takes it
    /// back. A pinned card stays, so it wears the other fastener: the
    /// pushpin drawn at Resources/Pushpin.png, turned needle-down and
    /// stretched to the metal clip's own slenderness, so a pinned card
    /// hangs from something the same size as the clip it replaced. The
    /// frame keeps that clip's height, and the note's taller one, so the
    /// card below hangs from the rope at exactly the same point either
    /// way. If the art is missing — a bare binary outside the app bundle —
    /// the system's pin glyph draws instead, and a card never hangs from
    /// nothing.
    private var pinnedMark: some View {
        Group {
            if let pin = Self.pushpinArt {
                Image(nsImage: pin)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: item.payload.isNote ? 36 : 26)
            } else {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: item.payload.isNote ? 36 : 26)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
        .accessibilityLabel(L("Pinned"))
        .allowsHitTesting(false)
    }

    private static let pushpinArt: NSImage? = Bundle.main
        .path(forResource: "Pushpin", ofType: "png")
        .flatMap { NSImage(contentsOfFile: $0) }

    var body: some View {
        // The peg is the note's own: a wooden clothespin belongs to paper,
        // the way a spring clip belongs to everything else. The overlap
        // differs with the clip — the wooden peg is longer and bites deeper,
        // the metal pill just pinches the edge — and only the note's overlap
        // reaches into the card, which its top pad can afford. A pinned
        // card hangs from the pushpin instead, at the same height.
        VStack(spacing: item.payload.isNote ? -22 : -12) {
            if item.pinned {
                pinnedMark
                    .zIndex(1)
            } else {
                Clothespin(wooden: item.payload.isNote)
                    .zIndex(1)
            }
            card
        }
        .rotationEffect(.degrees(swing + item.tilt), anchor: .top)
        .offset(y: arrived ? 0 : -46)
        // The fall itself is drawn over the whole screen by CaptureFlight, so
        // the card here just steps aside at once.
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onChange(of: item.flying) { was, now in if was && !now { land() } }
        .onChange(of: line.gust) { _, _ in breeze() }
        .onChange(of: copied) { _, isCopied in if isCopied { nudge(3) } }
    }

    /// The photo fits inside the card area keeping its proportions, so the
    /// white border hugs it whether the screenshot is wide or tall.
    static func photoSize(for size: CGSize) -> CGSize {
        let maxW = Layout.cardWidth - 14, maxH: CGFloat = 104
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The card around the photo: the photo plus the glass inset.
    static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CGSize(width: p.width + Frame.inset * 2, height: p.height + Frame.inset * 2)
    }

    /// Distance from the top of the hanging view (the clip) to the card.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    /// A picture keeps its own proportions. Text has no thumbnail, so its card is
    /// the fixed size instead.
    private var photoSize: CGSize {
        guard let thumb = item.thumb else { return PayloadCard.size(of: item.payload) }
        return Self.photoSize(for: thumb.size)
    }

    @ViewBuilder
    private var card: some View {
        switch item.payload {
        case .image:
            imageCard
        case .text:
            textCard
        case .file:
            fileCard
        case .note(let note):
            noteCard(note)
        }
    }

    private var imageCard: some View {
        let missing = fileMissing
        return cardContent {
            Image(nsImage: item.thumb ?? NSImage(size: .zero))
                .resizable()
                .interpolation(.high)
                .opacity(missing ? 0.45 : 1)
                .frame(width: photoSize.width, height: photoSize.height)
                // Concentric corners: the photo's radius is the frame's minus the
                // inset, the way macOS rounds nested shapes.
                .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .padding(Frame.inset)
        }
    }

    /// Whether the files this card points at have gone — read from disk each
    /// time the card is drawn, so a deletion behind the app's back shows the
    /// next time the line stirs rather than never. A picture card asks too:
    /// its copy lives in the app's folder, and that folder is not beyond the
    /// user's own hand.
    private var fileMissing: Bool {
        item.payload.files.contains { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What a missing file says: the whole file when every path is gone, the
    /// part when only some of a selection is.
    private var missingLabel: String {
        let allGone = item.payload.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        return allGone ? L("Original file deleted") : L("Some files deleted")
    }

    /// A file hangs as what it is: a name and the icon the Finder would show,
    /// on the same paper a note is written on. Not a thumbnail — a document
    /// looks like itself at this size, and a thumbnail of the first page
    /// would be a picture of a file, which is a step removed from the file.
    /// A file that is a picture never gets here: it hangs as the image it is.
    private var fileCard: some View {
        // The file can be gone while the card still hangs — deleted behind
        // the app's back, moved, renamed. The state is read from disk each
        // time the card is drawn, and the card is drawn again whenever the
        // line stirs, so what was lost while the line was away comes up
        // greyed the next time the line comes down.
        let missing = fileMissing
        return cardContent {
            VStack(spacing: 0) {
                // A stack, the way the Finder draws a pile of files: the
                // front one whole, the ones behind it showing an edge. Four
                // fit across the card at this size; a fifth would be a stripe
                // rather than a file, and the count underneath says what the
                // stack is not showing.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(fileIcons.enumerated()), id: \.offset) { index, icon in
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 32, height: 38)
                            .offset(x: CGFloat(index) * 8 - CGFloat(max(0, fileIcons.count - 1)) * 4,
                                    y: CGFloat(abs(index - fileIcons.count / 2)) * -1.5)
                            .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                    }
                }
                .frame(width: 88, height: 42)
                .padding(.top, 12)

                Text(fileName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 7)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)

                if missing {
                    Text(missingLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                } else if fileCount > 1 {
                    Text(countLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .padding(.top, 2)
                } else if let caption = caption {
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                }
            }
            .opacity(missing ? 0.45 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(width: PayloadCard.size(of: item.payload).width,
                   height: PayloadCard.size(of: item.payload).height)
            .background(PaperSheet())
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius, style: .continuous))
            .padding(Frame.inset)
        }
    }

    /// A note hangs as a sheet of paper with lines written on it.
    ///
    /// The same paper a snippet is written on, the same glass around it and
    /// the same clip over it, so it reads as one of the things on this line
    /// rather than as a small app that has appeared among them.
    ///
    /// What is different is that the sheet is the size of what is written on
    /// it. Same width as everything else — two widths on one line stop reading
    /// as a row of pegs — and a height that comes from the contents, because a
    /// note is the one card on this line whose subject is not a fixed frame
    /// with something in it.
    private func noteCard(_ note: Note) -> some View {
        let arrangement = NoteCardLayout.arrange(note)
        // What the wheel has to work with: the distance between the paper at
        // full length and the paper as hung. Zero when everything fits, and
        // then the card does not scroll at all.
        let scrollMax = max(0, arrangement.fullHeight - arrangement.height)
        // Clamped here rather than trusted: the note may have been edited
        // shorter since the last turn of the wheel.
        let offset = min(noteScroll, scrollMax)
        // The window the rows are seen through: the card between its top pad
        // and its caption. Taller than the window is the paper's own business.
        let region = arrangement.height - NoteCardLayout.topPad
            - NoteCardLayout.captionHeight - NoteCardLayout.bottomPad
        // The sheet this note is on: its own when it picked one, the line's
        // when it did not.
        // The colour this note picked, when it did; the paper's own when it
        // did not. The colour is the whole of what there is to pick now —
        // every sheet is a plain one.
        let tint = note.tint
        return cardContent(noteScroll: $noteScroll) {
            VStack(spacing: 0) {
                // The card's own top, before the first line. The two corners
                // above belong to the cross and the corner mark, and a line
                // drawn up there would put its square underneath the cross —
                // which would make pressing the first box throw the note away.
                Color.clear.frame(height: NoteCardLayout.topPad)

                // Every row the note has, slid up behind the window by however
                // far the wheel has taken it. Nothing is left out of the layout
                // any more: what does not fit in the window is not counted and
                // offered as a number, it is simply below, and scrolling is
                // how it is read — because the contents are the point of a
                // note, and a line nobody can see is a line nobody wrote down.
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(Array(arrangement.rows.enumerated()), id: \.offset) { _, row in
                            noteRow(row, items: arrangement.items, tint: tint)
                        }
                    }
                    .offset(y: -offset)
                }
                .frame(height: region, alignment: .top)
                .clipped()
                // The wheel's own directions, shown while they have somewhere
                // to go. The one above is the half this feature nearly forgot:
                // once the paper has been rolled down, the beginning of the
                // note is the part nobody can see, and it deserves the same
                // word as the end. Each appears only while its direction has
                // content — which is why there are two and not a bar: a bar
                // would have to be here all the time to say what each of
                // these says only when it is true.
                .overlay(alignment: .top) {
                    if offset > 0.5 {
                        noteChevron("chevron.up", tint: tint)
                            .offset(y: -9)
                    }
                }
                .overlay(alignment: .bottom) {
                    if offset < scrollMax - 0.5 {
                        noteChevron("chevron.down", tint: tint)
                            .offset(y: 9)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: offset > 0.5)
                .animation(.easeOut(duration: 0.18), value: offset < scrollMax - 0.5)

                noteFooter(tint)
                // The card's own bottom, after the caption. The window above
                // is a fixed height and the footer is a fixed height, so what
                // is left of the card is exactly the layout's bottom pad — the
                // spacer hands it over rather than letting the stack centre
                // itself, which would slide every row five points off the
                // place the tick hit-testing believes them to be.
                Spacer(minLength: 0)
            }
            .frame(width: PayloadCard.size(of: item.payload).width,
                   height: PayloadCard.size(of: item.payload).height)
            .background(PaperSheet(tint: tint))
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius, style: .continuous))
            .padding(Frame.inset)
            // A note with everything ticked off stays where it is and fades,
            // rather than coming down.
            //
            // It is still a record of what was done, and the next thing to do
            // is usually added to the list that was already there — so a card
            // that took itself off the line when the last box was ticked would
            // be the app deciding the note was finished, which is the one
            // thing about a note it cannot know. Taking it down is the cross's
            // job, and the cross says what it does before it does it.
            //
            // The ink fades and the glass does not, so a finished note reads
            // as a note that is done rather than as a card that has broken.
            .opacity(note.isAllDone ? 0.55 : 1)
        }
    }

    /// One line of a note: the mark, where there is one, and the words.
    ///
    /// The words of a list line are indented past its mark and the words of
    /// prose are not, which is how a list reads everywhere else. The first
    /// line is set in the heavier face when it is prose, and it is the title
    /// because it is first — not because anything declared it one.
    ///
    /// Every line of the note gets one of these, whether or not it is inside
    /// the card's window: the ones below the fold are scrolled to, not counted.
    @ViewBuilder
    private func noteRow(_ row: NoteCardLayout.Row, items: [NoteItem], tint: NoteTint?) -> some View {
        let line = items[row.index]
            HStack(spacing: 0) {
                // The mark and the room it takes, drawn only where there is a
                // mark — a box for a thing to do, a number for a numbered one.
                // Prose starts at the edge of the paper and a list line starts
                // past its mark, which is how a list reads everywhere else.
                //
                // The column is a fixed width whatever is in it, so that a
                // line of ticks and a line of numbers start their words in the
                // same place. The rectangle a press is tested against is the
                // same column — the box drawn in it is nine points across and
                // the target around it is the whole of it, so a press aimed at
                // the mark lands on the mark rather than near it.
                if row.hasMarker {
                    Group {
                        if row.box != nil {
                            noteBox(done: line.isDone, tint: tint)
                        } else if let number = row.number {
                            Text("\(number).")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(noteInk(tint).opacity(0.7))
                                .lineLimit(1)
                        } else if row.bullet {
                            // A dot for a line that is a bullet and not a
                            // thing to do. Drawn and not pressed: there is
                            // nothing in the text behind it to tick, so the
                            // press belongs to the card.
                            Circle()
                                .fill(noteInk(tint).opacity(0.7))
                                .frame(width: 3, height: 3)
                        }
                    }
                    .frame(width: NoteCardLayout.markerColumn, alignment: .center)
                    Spacer().frame(width: NoteCardLayout.boxGap)
                }
                inlineText(line.text, size: 12)
                    .font(.system(size: 12))
                    // Struck through and dimmed together. The line alone is not
                    // enough at this size: at twelve points in a dark room a
                    // strike reads as a smudge, and what has to be legible at a
                    // glance is which of these is done.
                    .foregroundStyle(line.isDone ? noteInk(tint).opacity(0.45) : noteInk(tint))
                    .strikethrough(line.isDone, color: noteInk(tint).opacity(0.45))
                    // The words take the lines the layout measured for them:
                    // one for most, more for the long ones, and the room the
                    // row was given is the room they wrap into. What does not
                    // fit in three is the editor's to show whole.
                    .multilineTextAlignment(.leading)
                    .lineLimit(row.lines)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NoteCardLayout.sidePad)
            .frame(height: row.rect.height)
    }

    /// One line of a note as it is drawn: the words with the face the inline
    /// mark asks for, and the mark itself off the card.
    ///
    /// The card is the rendered truth. It already takes the list marks off
    /// and draws a square in their place, and the delimiters go the same
    /// way: `**` asks for bold, it does not ask to be seen. The spans are
    /// the card's own reading and the editor's — one parse, two sides that
    /// cannot disagree.
    private func inlineText(_ line: String, size: CGFloat) -> Text {
        let ns = line as NSString
        let spans = NoteInline.spans(in: line)
        guard !spans.isEmpty else { return Text(line) }

        var text = Text("")
        var cursor = 0
        let drops = spans.flatMap(\.delimiters).sorted { $0.location < $1.location }
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            let words = ns.substring(with: range)
            if let span = spans.first(where: { NSIntersectionRange($0.inner, range).length == range.length }) {
                text = text + Text(words).bold()
            } else {
                text = text + Text(words)
            }
        }
        for drop in drops {
            guard drop.location >= cursor else { continue }
            append(NSRange(location: cursor, length: drop.location - cursor))
            cursor = drop.location + drop.length
        }
        append(NSRange(location: cursor, length: ns.length - cursor))
        return text
    }

    /// The square that can be pressed.
    ///
    /// Drawn here and hit through GrabView, which sits on top — the same
    /// arrangement the cross and the corner mark use, and for the same reason:
    /// a button drawn underneath the view that takes the press is a drawing.
    private func noteBox(done: Bool, tint: NoteTint?) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(done ? noteInk(tint).opacity(0.45) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(noteInk(tint).opacity(0.45), lineWidth: 1)
            )
            .overlay {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(sheetUnder(tint: tint))
                }
            }
            .frame(width: NoteCardLayout.boxSize, height: NoteCardLayout.boxSize)
    }

    /// The sheet under a tick — the colour the check is cut out of, and the
    /// same colour the editor's own tick reads, so a box is one box on both
    /// sides of one note.
    private func sheetUnder(tint: NoteTint?) -> Color {
        NoteTint.background(for: tint, in: scheme)
    }

    /// The ink this note is read in: the system's own over the system's
    /// paper, and always dark over a colour the note picked — the picked
    /// colour is light in both appearances, so the ink is what bends.
    private func noteInk(_ tint: NoteTint?) -> Color {
        NoteTint.ink(for: tint, in: scheme)
    }

    /// When the note was last written in, along the bottom.
    ///
    /// The same place and the same rule as a snippet's caption, and only the
    /// time in it. A copy's caption names the app it came from and a note came
    /// from nowhere, so what is left is the one thing about a note's history
    /// that cannot be worked out by reading the note.
    private func noteFooter(_ tint: NoteTint?) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(noteInk(tint).opacity(0.12))
                .frame(height: 0.5)
                .padding(.horizontal, 9)

            Text(item.origin.noteCaption())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(noteInk(tint).opacity(0.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
        }
        // A fixed height, and the number belongs to the layout rather than to
        // this view. `NoteCardLayout` counts the caption when it works out how
        // many lines fit on the card, so a footer that chose its own height
        // would make the two disagree — and the line the disagreement costs is
        // the last one, which is the one under the caption.
        .frame(height: NoteCardLayout.captionHeight)
    }

    /// The wheel's word for "there is more this way": a small chevron cut
    /// into the paper, drawn only while that direction has content.
    ///
    /// The capsule behind it is the sheet's own colour, so the mark reads as
    /// a notch in the paper rather than as ink floating over the words — the
    /// same cut-out trick the tick's checkmark uses, and for the same reason:
    /// a hint that legible means sitting on its own ground, not on the text
    /// it happens to overlap.
    private func noteChevron(_ system: String, tint: NoteTint?) -> some View {
        Image(systemName: system)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(noteInk(tint).opacity(0.45))
            .frame(width: 18, height: 13)
            .background(Capsule().fill(sheetUnder(tint: tint)))
            .allowsHitTesting(false)
    }

    /// How many files the card holds, and the icons for as many of them as
    /// there is room to draw.
    private var fileCount: Int { item.payload.files.count }

    private var fileIcons: [NSImage] {
        Array(item.payload.files.prefix(4)).map(fileIcon(for:))
    }

    /// "3 files", or "20 files" — the count is the thing the stack cannot
    /// show past its third edge.
    private var countLabel: String {
        fileCount == 1
            ? L("1 file")
            : String(format: L("%lld files"), fileCount)
    }

    /// The icon the Finder shows for this file, or a page when it has none
    /// to show — which is the case for something that has since been moved.
    private func fileIcon(for url: URL) -> NSImage {
        let generic = NSWorkspace.shared.icon(for: .data)
        // A missing file's icon is a question mark, which reads as an error
        // rather than as the thing itself.
        guard FileManager.default.fileExists(atPath: url.path) else { return generic }
        // The icon of what the file is, not of its name: a document renamed
        // from .txt to .md should look like what it now is.
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// What the card calls itself.
    ///
    /// One file is named by itself, extension and all: the extension is half
    /// of what a file is, and a card reading "Desktop" for something the
    /// Finder calls "Desktop.pdf" is a card that cannot be told apart from
    /// the folder.
    ///
    /// Several are named after where they are, because that is what tells
    /// them apart — three PDFs from three folders are three documents and
    /// their names say nothing. When they are not all in the same place there
    /// is no one place, so the number of places is what the card says.
    private var fileName: String {
        let files = item.payload.files
        guard let first = files.first else { return "" }
        if files.count == 1 { return first.lastPathComponent }
        let folders = Set(files.map { $0.deletingLastPathComponent().lastPathComponent })
        if folders.count == 1 { return folders.first ?? first.lastPathComponent }
        // Not translated: it is a number and a noun that only appear when
        // a selection is spread across several folders, and a card that says
        // "4 places" says it in any language the Finder does.
        return "\(folders.count) \(folders.count == 1 ? "place" : "places")"
    }

    /// What the corner says this will do: somewhere to go for a folder or a
    /// link, a window to look into for anything else.
    private var zoomSymbol: String {
        switch item.payload {
        case .file(let urls):
            // One folder is a place to go. One file is a thing to look into.
            // Several are a list to look at, which is not the same thing as a
            // document but is still a window — a mark that says "a list" is
            // more honest than a magnifier over three documents.
            guard urls.count == 1 else { return "list.bullet" }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: urls[0].path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
                ? "folder.fill.badge.plus" : "magnifyingglass"
        case .text:
            return PayloadCard.isLink(item.payload) ? "safari.fill" : "magnifyingglass"
        case .image:
            return "magnifyingglass"
        case .note:
            // A pencil and not a magnifier. A magnifier over a note promises a
            // bigger copy of it, and what the press actually does is open the
            // note for writing — and this mark is the only thing on the card
            // that says which of the two is coming.
            return "square.and.pencil"
        }
    }

    /// The magnifier in the top right, drawn and not pressed here.
    ///
    /// The press is handled by the view that covers the card — the same
    /// arrangement as the cross, and for the same reason. A SwiftUI button
    /// underneath that view is a drawing: the view above takes the press,
    /// which is what a card does with a press, and the magnifier opens
    /// nothing. So the mark is drawn here and answered there.
    private var zoomMark: some View {
        Image(systemName: zoomSymbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 20, height: 20)
            .glassFrame(circle: true)
            .opacity(hovering && !dragging ? 1 : 0)
            .scaleEffect(hovering ? 1 : 0.6)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .allowsHitTesting(false)
    }


    private var zoomAnchor: NSPoint {
        guard let rect = line.hitRects[item.id] else { return .zero }
        let panel = line.panelFrame
        return NSPoint(x: panel.minX + rect.midX, y: panel.minY + rect.minY)
    }

    /// One of the two marks in a card's top corners: the cross on the left,
    /// the magnifier on the right.
    ///
    /// Drawn here and hit through GrabView, which sits on top — the same
    /// arrangement for both, which is why they sit in one overlay rather than
    /// two. Hidden while dragging: a card being carried somewhere has no
    /// business opening anything on the way.
    ///
    /// The magnifier is a button rather than a key, and that is the whole of
    /// why. The line is a strip over the top of the screen that cannot take
    /// focus, so it is never the app a key is delivered to, and the only
    /// monitor that hears a key pressed elsewhere cannot take it back — which
    /// means every key the line offers also arrives in whatever app the user
    /// is in. A space there is a space where you were typing, and a second
    /// preview if that app has its own idea of what a space does with a
    /// picture. There is no key available that does not arrive somewhere it
    /// was not aimed, so the line uses a button and no key at all.
    private func cornerBadge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 20, height: 20)
            .glassFrame(circle: true)
            .opacity(hovering && !dragging ? 1 : 0)
            .scaleEffect(hovering ? 1 : 0.6)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .allowsHitTesting(false)
    }

    /// Text hangs as a written note rather than a picture: the point is that
    /// it can be read from across the desk, so it is typeset at a readable
    /// size instead of being blown up from a thumbnail.
    ///
    /// The card is a sheet of paper on the same glass everything else is on.
    /// A screenshot brings its own ground — it is whatever was on the screen,
    /// mostly light — and the glass frames it. A snippet brings nothing, so
    /// it gets the paper: an opaque ground under the glass, which is the
    /// same arrangement as a photograph, and the reason a note reads the way
    /// a photo does rather than looking like ink floating in a pane of glass.
    private var textCard: some View {
        cardContent {
            VStack(spacing: 0) {
                Text(textBody)
                    .font(PayloadCard.font(for: item.payload))
                    .lineLimit(textLines)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)

                if let caption = caption {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 0.5)
                        .padding(.horizontal, 9)
                        .padding(.top, 5)

                    Text(caption)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                        .padding(.bottom, 7)
                }
            }
            .frame(width: PayloadCard.size(of: item.payload).width,
                   height: PayloadCard.size(of: item.payload).height)
            // A colour card is its own colour, so the value and the sample
            // are one thing: you see the colour and what made it together,
            // which is the reason to hang it rather than read it elsewhere.
            // The ink flips so the value stays readable on a dark sample.
            .background(item.payload.colorValue?.color ?? PayloadCard.paper)
            .foregroundStyle(item.payload.colorValue.map { Self.ink(on: $0.color) } ?? .primary)
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius, style: .continuous))
            .padding(Frame.inset)
        }
    }

    /// Black on a light sample, white on a dark one. Perceived brightness
    /// rather than the raw average: a saturated blue and a dark navy have
    /// the same mean and need opposite inks.
    private static func ink(on color: Color) -> Color {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let brightness = 0.299 * ns.redComponent + 0.587 * ns.greenComponent
            + 0.114 * ns.blueComponent
        return brightness > 0.6 ? .black : .white
    }

    /// `app · time · count` along the bottom, when the card is wide enough to
    /// hold it. Nil for a picture, and nil when there is nothing to say.
    private var caption: String? {
        let inner = PayloadCard.size(of: item.payload).width - 18
        return item.origin.caption(for: item.payload, fits: inner)
    }

    /// The text as it was copied. Line breaks stay: in a snippet they are
    /// structure, and joining them into one line makes code unreadable.
    private var textBody: String {
        guard case .text(let string, _) = item.payload else { return "" }
        return string
    }

    /// How many lines the body gets. The caption along the bottom takes the rest
    /// of the card, so a card with one shows one line fewer. Code fits more
    /// because its face is smaller and it can break anywhere.
    private var textLines: Int {
        guard case .text(_, let isCode) = item.payload else { return 5 }
        let base = isCode ? 6 : 5
        return caption == nil ? base : base - 1
    }

    // MARK: Shared chrome

    /// Wraps one kind of card in the glass, shadow and press that every card
    /// shares, and reports where it landed so the panel only catches clicks
    /// over it.
    ///
    /// One material for the whole line. A text card is the same glass as a
    /// picture and stays legible on it because the ink carries its own halo,
    /// which is the difference between material and background.
    ///
    /// `noteScroll` is the note's own wheel position, handed to the view that
    /// takes the presses — the wheel is heard through the same overlay that
    /// hears everything else on a card, because the overlay is on top and a
    /// scroll view underneath it would never be touched.
    private func cardContent(noteScroll: Binding<CGFloat> = .constant(0),
                             @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
                    .stroke(Edge.gradient, lineWidth: 0.75)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
                    .stroke(Edge.rim, lineWidth: 0.5).padding(-0.5)
            )
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
            // Holding presses the card in slowly, so a long press feels like
            // it is building up to something.
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.035 : 1), anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .top) {
                // Both corners in one overlay: two chained overlays on a
                // view this decorated made the compiler give up on it, and
                // there is nothing between them that an alignment could
                // reach differently.
                HStack {
                    cornerBadge("xmark")
                    // The blue pushpin that used to mark a pinned card here
                    // is retired: at the card's top corner it read as the
                    // thing holding the card up, which the clothespin is,
                    // and the two fasteners told opposite stories at once.
                    // What is pinned still says so — the pin in the pill
                    // filters the rope to pinned cards, and the pushpin
                    // above the middle of the rope is where a pinned card
                    // is made.
                    Spacer(minLength: 0)
                    zoomMark
                }
                .padding(3)
            }
            .overlay(GrabArea(item: item, line: line, noteScroll: noteScroll))
            .overlay(alignment: .bottom) {
                if copied {
                    Label(L("Copied"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassFrame(capsule: true)
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling ? [:] : [item.id: g.frame(in: .named("lineSpace"))])
                }
            )
    }

    private func arrive() {
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            return
        }
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    /// Landing after the flight: no jump, just a small sway from rest.
    private func land() {
        nudge(2.2)
    }

    private func breeze() {
        let delay = Double.random(in: 0...0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

enum Frame {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

/// The thin specular line every piece of glass here is drawn with, lit from
/// above: a bright edge on top, a faint one at the bottom, and one very thin
/// rim around the outside.
///
/// Both ends of it change with the appearance, and they change in opposite
/// directions. The specular edge is white in the light and *less* white in
/// the dark — a highlight that keeps full strength on a dark card is not a
/// lit edge, it is a bright outline. The rim is the other way round: black in
/// the light, where a card needs a boundary against a pale background, and
/// white in the dark, where it needs the same boundary against a dark one.
///
/// One line, two backgrounds, one rule — it has to be lighter or darker than
/// what it sits on, and which of those it is depends on what it sits on.
enum Edge {
    static let top = shade(light: (1, 1, 1, 0.55), dark: (1, 1, 1, 0.20))
    static let bottom = shade(light: (1, 1, 1, 0.12), dark: (1, 1, 1, 0.06))
    static let rim = shade(light: (0, 0, 0, 0.10), dark: (1, 1, 1, 0.13))
    /// The rope the cards hang from. Neutral grey in the light; in the dark it
    /// has to become a low-alpha white, because mid grey on a dark ground is
    /// not a rope, it is a bright scar across the screen.
    static let rope = shade(light: (0.55, 0.55, 0.55, 1), dark: (1, 1, 1, 0.32))

    static var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    static func shade(light: (CGFloat, CGFloat, CGFloat, CGFloat),
                              dark: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }
}

extension View {
    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. No refraction, so the background stays sharp
    /// around the frame instead of bending like gel.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(Edge.gradient, lineWidth: 0.75)
            )
            .overlay(shape.stroke(Edge.rim, lineWidth: 0.5).padding(-0.5))
    }
}

/// A wooden clothespin, the kind that actually grips: two sprung wooden
/// jaws and a steel spring, drawn once as art and hung on note cards.
///
/// The art lives at Resources/Peg.png (copied into the app by the build
/// script, like the translations). If it is missing — a bare binary run
/// outside the app bundle — the metal pill draws instead, so a card
/// never hangs from nothing.
struct Clothespin {
    var wooden: Bool = false

    /// The wooden peg's own size, at its natural slenderness: eleven points
    /// across, thirty-six down, the spring landing on the card's edge.
    private static let woodenSize = CGSize(width: 11, height: 36)
    private static let art: NSImage? = Bundle.main
        .path(forResource: "Peg", ofType: "png")
        .flatMap { NSImage(contentsOfFile: $0) }
}

extension Clothespin: View {
    var body: some View {
        if wooden, let peg = Self.art {
            Image(nsImage: peg)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.woodenSize.width, height: Self.woodenSize.height)
                .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                .allowsHitTesting(false)
        } else {
            metalPill
        }
    }

    /// The drawn stand-in: a minimal aluminium pill with a slot where it
    /// grips the line, and the clip every card that is not a note wears.
    private var metalPill: some View {
        let metal = LinearGradient(
            stops: [
                .init(color: Color(white: 0.70), location: 0),
                .init(color: Color(white: 0.93), location: 0.35),
                .init(color: Color(white: 0.82), location: 0.65),
                .init(color: Color(white: 0.62), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)

        return RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                // The slot the line passes through.
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}
