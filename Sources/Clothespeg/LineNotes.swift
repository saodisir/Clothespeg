import AppKit

/// The notes half of the line: getting a note onto it, and the things that can
/// be done to one that is already there.
///
/// An extension rather than a second type, because it is the same line. The
/// panel, the rope, the glass, the drag, the press and the panning are one set
/// of things and they are already written; what the notes deck adds is a
/// second list to put on that line. Kept in a file of its own so the two
/// halves can be read apart, which is also the reason they are kept apart at
/// all.
extension Line {

    // MARK: Getting one onto the line

    /// A finished note goes on the line.
    ///
    /// Not through `hang`, which is the clipboard's door and has the
    /// clipboard's rules standing in it. That one drops a card repeating the
    /// one before it, because copying the same thing twice is one copy pressed
    /// twice — and writing the same two lines twice is two notes. A note is
    /// the one card that must never be thrown away by a rule about copies, and
    /// that rule is most of the reason this is a method of its own rather than
    /// another case inside `hang`.
    func hang(note: Note) {
        guard !note.isBlank else { return }
        // Newest first, like everything else on this line.
        notes.insert(Pegged(payload: .note(note)), at: 0)
        // The deck follows the note rather than the note following the deck: a
        // note just written is a note to look at, and showing something else
        // would be the app taking the writing and then turning away from it.
        deck = .notes
        panToNewest()
        saveNotes()
        // Said out loud, because a line does not know whether it is on screen
        // and the window that just finished a note is not the thing that puts
        // one there. A note written and then not shown reads as a note that
        // was lost, which is the one impression this must never give.
        NotificationCenter.default.post(name: .noteHung, object: nil)
    }

    /// A note the cross was pressed on.
    ///
    /// Faded and then gone, the way a card leaves the line, and saved before
    /// the fade rather than after: the file is what the note *is*, and a quit
    /// during the sixth of a second a card spends falling would bring back a
    /// note that was taken down.
    ///
    /// Nothing is asked about a file on disk, because a note has none, and
    /// nothing is removed from the history, because a note was never in it.
    /// This is the whole of what taking a note down involves.
    func removeNote(_ id: UUID, quietly: Bool = false) {
        guard let i = notes.firstIndex(where: { $0.id == id }), !notes[i].falling else { return }
        notes[i].falling = true
        hitRects[id] = nil
        // A lit card going down takes its light with it, and the system's
        // pending reminder goes with the save that follows.
        if highlightedNoteID == id { highlightedNoteID = nil }
        saveNotes()
        if !quietly { play(.remove) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.notes.removeAll { $0.id == id }
        }
    }

    /// The card was opened and written in again: it changes rather than being
    /// joined by a second one, which is the whole of what makes an edit an
    /// edit.
    func rewrite(_ id: UUID, to note: Note) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].payload = .note(note)
        // What the line along the bottom of the card says. Set here as well as
        // when the note is made, because for a note that line is about the
        // writing rather than about the arrival.
        notes[i].origin.at = Date()
        // A reminder taken off the note puts its own light out: the card was
        // lit to say "this one rang", and the person who just removed the
        // reminder is the person it rang for.
        if note.remindAt == nil, highlightedNoteID == id {
            highlightedNoteID = nil
        }
        saveNotes()
    }

    // MARK: A reminder ringing

    /// A reminder rang for one of the notes on this line.
    ///
    /// The one-time kind takes its mark here: it has rung, and the card
    /// keeps the trace until the reminder is removed. The repeating kind
    /// has no "after" to mark — it will ring again on its own. Either way
    /// the card is lit, and the rope was already on its way down.
    func noteReminderArrived(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }),
              case .note(var note) = notes[i].payload else { return }
        if note.remindRule == nil {
            note.remindFired = true
            notes[i].payload = .note(note)
        }
        highlightedNoteID = id
        // A bell, because a reminder that arrives in silence is easy to
        // miss and easy to have missed. Hero over Ping: the one-second
        // chime survived the first test where the quarter-second tick did
        // not — a sound too short to hear is a sound that did not ring.
        play(.reminder)
        saveNotes()
    }

    /// The ringing card was opened, and the person it rang for has seen it.
    func clearNoteHighlight(_ id: UUID) {
        if highlightedNoteID == id { highlightedNoteID = nil }
    }

    // MARK: Ticking one off

    /// A line of a note was ticked, or unticked.
    ///
    /// The tick is a character in the note itself — `[ ]` becomes `[x]` — so
    /// this is a change to the text and only one line of it. Which is also why
    /// the editor and this cannot disagree: there is nothing to keep in step,
    /// because there is only the one copy of the note and both are reading it.
    ///
    /// The whole card is rebuilt rather than patched, because a card is a
    /// value: there is no reference into the middle of one to change, and the
    /// redraw that follows from the new one is what makes the tick appear at
    /// all.
    func tick(_ id: UUID, row: Int) {
        guard let i = notes.firstIndex(where: { $0.id == id }),
              case .note(let note) = notes[i].payload,
              let flipped = note.toggling(lineAt: row) else { return }
        notes[i].payload = .note(flipped)
        notes[i].origin.at = Date()
        saveNotes()
    }

    // MARK: Keeping them

    /// Every note is written out on every change.
    ///
    /// Unlike the history, which is saved because the line changed, this is
    /// saved because a note exists nowhere else — no file on disk, no
    /// pasteboard the system kept. Losing one to a quit is worse than the cost
    /// of writing a small file again, and there is no version of this that is
    /// worth being clever about.
    func saveNotes() {
        let entries = notes.filter { !$0.falling }
            .map { NoteStore.Entry(payload: $0.payload, origin: $0.origin, id: $0.id) }
        NoteStore.shared.save(entries)
        // The pending notifications agree with the file, through the same
        // door: a reminder set, rewritten or taken away has just walked
        // through it, and the system's list follows the notes rather than
        // the paths that changed them.
        let reminders = entries.compactMap { entry -> (id: UUID, note: Note)? in
            guard case .note(let note) = entry.payload else { return nil }
            return (entry.id, note)
        }
        ReminderScheduler.shared.reconcile(with: reminders)
    }

    /// The notes come back as they were, newest first.
    ///
    /// No window is applied to them, and that is the whole of the feature: a
    /// note written down to be kept is still here in a fortnight, and the
    /// history's fourteen days have nothing to say about it. Everything else
    /// about a note is an ordinary card; this is the one line that is not.
    func restoreNotes() {
        guard notes.isEmpty else { return }
        for entry in NoteStore.shared.load() {
            notes.append(Pegged(id: entry.id, payload: entry.payload, origin: entry.origin))
        }
        // A one-time reminder that rang while no one was watching keeps its
        // word as a mark rather than a ring: the banner has been and gone
        // by now, so what is left to say is "this rang", on the card, until
        // it is cleared.
        var missed = false
        let now = Date()
        for i in notes.indices {
            guard case .note(var note) = notes[i].payload,
                  !note.remindFired, note.remindRule == nil,
                  let at = note.remindAt, at <= now else { continue }
            note.remindFired = true
            notes[i].payload = .note(note)
            missed = true
        }
        if missed { saveNotes() }
    }
}
