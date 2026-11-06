import AppKit
import Foundation

/// The note's voice has one failure that costs nothing to compile and
/// everything to notice: `Note` is written out by hand, so a new field
/// forgotten in `tidied` or `toggling` still builds. A tick on a card then
/// quietly drops the recording, and a restart drops it again. This asks
/// those paths without a microphone or a window in the way.
enum NoteRecordingSelfTest {
    static func run() -> String {
        var lines: [String] = []
        let voice = Note.Recording(name: "probe.m4a", seconds: 12,
                                   bars: [10, 40, 80, 25])
        let words = "标题\n- [ ] 买牛奶"
        let note = Note(text: words, recording: voice)

        let data = (try? JSONEncoder().encode(note)) ?? Data()
        let readBack = (try? JSONDecoder().decode(Note.self, from: data)) ?? Note()
        lines.append(readBack == note
                     ? "note recording: round trip ok"
                     : "note recording: WRONG round trip lost the voice")

        // The note is saved wrapped in a payload, not bare. If that layer
        // ever grows its own Codable, a field it forgets is a field the
        // attic loses on the next launch.
        let wrapped = Payload.note(note)
        let wrappedData = (try? JSONEncoder().encode(wrapped)) ?? Data()
        let unwrapped = try? JSONDecoder().decode(Payload.self, from: wrappedData)
        lines.append(unwrapped?.note?.recording == voice
                     ? "note recording: payload saves the voice ok"
                     : "note recording: WRONG payload lost the voice")

        lines.append(note.tidied.recording == voice
                     ? "note recording: tidy keeps the voice ok"
                     : "note recording: WRONG tidy lost the voice")

        lines.append(note.toggling(lineAt: 1)?.recording == voice
                     ? "note recording: tick keeps the voice ok"
                     : "note recording: WRONG tick lost the voice")

        lines.append(!Note(text: "", recording: voice).isBlank
                     ? "note recording: voice-only note is a note ok"
                     : "note recording: WRONG voice-only note was dropped as blank")
        lines.append(Note(text: "").isBlank
                     ? "note recording: blank note stays blank ok"
                     : "note recording: WRONG blank note was kept")

        let without = NoteCardLayout.arrange(Note(text: words))
        let with = NoteCardLayout.arrange(note)
        let delta = with.fullHeight - without.fullHeight
        lines.append(abs(delta - NoteCardLayout.recordingHeight) < 0.01
                     ? "note recording: strip adds \(Int(NoteCardLayout.recordingHeight))pt ok"
                     : "note recording: WRONG strip height \(delta)")

        let bars = RecordingBars.from(Array(repeating: 30, count: 37))
        lines.append(bars.count == RecordingBars.count
                     ? "note recording: \(RecordingBars.count) bars ok"
                     : "note recording: WRONG bars \(bars.count)")

        // Thin bars with a wider swing. The ruler is untouched; only the
        // distance between its drawn floor and ceiling changed.
        let floor = RecordingBars.height(0)
        let ceiling = RecordingBars.height(100)
        lines.append(ceiling - floor >= 13 && ceiling <= 16.5
                     ? "note bars: height \(Int(floor))..\(Int(ceiling))pt ok"
                     : "note bars: WRONG height range \(floor)..\(ceiling)")

        // The ruler is absolute: -67 dB of room tone and -25 dB of speech
        // must not be drawn at the same height, and the answer must not
        // depend on which recording they came from.
        let roomTone = RecordingBars.level(-67)
        let speech = RecordingBars.level(-25)
        lines.append(speech - roomTone >= 30
                     ? "note bars: fixed ruler tone \(roomTone) speech \(speech) ok"
                     : "note bars: WRONG fixed ruler flattened \(roomTone) and \(speech)")

        // Two steady sounds at different volumes used to be stretched into
        // the same tall wave. They must now keep their difference.
        let soft = RecordingBars.from(Array(repeating: 22, count: 90))
        let loud = RecordingBars.from(Array(repeating: 75, count: 90))
        lines.append((loud.first ?? 0) - (soft.first ?? 0) >= 40
                     ? "note bars: soft \(soft.first ?? 0) stays below loud \(loud.first ?? 0) ok"
                     : "note bars: WRONG soft and loud were stretched alike")

        // A steady sound stays steady. Nothing is normalised into a shape
        // the microphone never heard.
        let steady = RecordingBars.from(Array(repeating: 30, count: 90))
        lines.append(Set(steady).count == 1 && steady.allSatisfy { $0 == 30 }
                     ? "note bars: steady sound stays flat ok"
                     : "note bars: WRONG steady sound was given a wave \(steady)")

        // A pause and a word in one recording still read as different bars.
        let mixed = RecordingBars.from(
            Array(repeating: 12, count: 40) + Array(repeating: 78, count: 60))
        let spread = (mixed.max() ?? 0) - (mixed.min() ?? 0)
        lines.append(spread >= 50
                     ? "note bars: pause and word differ (spread \(spread)) ok"
                     : "note bars: WRONG passages collapsed \(spread)")

        // A recording still being made grows one bar per reading; the rest
        // of the strip stays empty rather than repeating its first moment.
        let growing = RecordingBars.from([12, 40])
        lines.append(growing.count == RecordingBars.count
                     && growing[0] == 12 && growing[1] == 40
                     && growing.dropFirst(2).allSatisfy { $0 == 0 }
                     ? "note bars: short recording grows one bar at a time ok"
                     : "note bars: WRONG short recording \(growing)")

        let empty = RecordingBars.from([])
        lines.append(empty.count == RecordingBars.count && empty.allSatisfy { $0 == 0 }
                     ? "note bars: no samples draws a low flat wave ok"
                     : "note bars: WRONG empty wave \(empty)")
        let silence = RecordingBars.from(Array(repeating: 0, count: 90))
        lines.append(silence.allSatisfy { $0 <= 3 }
                     ? "note bars: silence stays flat ok"
                     : "note bars: WRONG silence was amplified \(silence)")

        // Playback gain is decided from the file's own peak, with a ceiling
        // so a recording of room tone is not turned into a wall of hiss.
        let quiet = PlaybackGain.gainDb(peak: 0.056)   // about -25 dBFS
        let mastered = PlaybackGain.gainDb(peak: 0.71) // about -3 dBFS
        let noise = PlaybackGain.gainDb(peak: 0.0003)  // about -70 dBFS
        lines.append(quiet > 17 && quiet < 21 && mastered == 0 && noise == PlaybackGain.ceilingDb
                     ? "note gain: quiet +\(String(format: "%.0f", quiet)) dB, "
                       + "loud 0 dB, noise capped at \(Int(PlaybackGain.ceilingDb)) dB ok"
                     : "note gain: WRONG boosts \(quiet)/\(mastered)/\(noise)")
        lines.append(PlaybackGain.gain(peak: 0.056) > 1 && PlaybackGain.gain(peak: 0) == 1
                     ? "note gain: multiplier stays sane ok"
                     : "note gain: WRONG multiplier")

        // The card's slider: the drawing and the press target must agree on
        // exactly the same stretch of paper. A track that changes width in
        // one place only is a wave that seeks to the wrong moment.
        let laidOut = (NoteCardLayout.recordingSidePad
                       + NoteCardLayout.recordingPlayWidth
                       + NoteCardLayout.recordingPlayGap
                       + NoteCardLayout.recordingTrackWidth
                       + NoteCardLayout.recordingPlayGap
                       + NoteCardLayout.recordingClockWidth
                       + NoteCardLayout.recordingSidePad)
        lines.append(abs(laidOut - NoteCardLayout.width) < 0.01
                     && NoteCardLayout.recordingTrackWidth > 100
                     ? "note track: \(Int(NoteCardLayout.recordingTrackWidth))pt of the card is the slider ok"
                     : "note track: WRONG geometry \(laidOut) vs \(NoteCardLayout.width)")
        lines.append(RecordingBars.bar(for: 0) == 0
                     && RecordingBars.bar(for: 0.5) == 10
                     && RecordingBars.bar(for: 1) == 19
                     && RecordingBars.bar(for: -1) == 0
                     && RecordingBars.bar(for: 2) == 19
                     ? "note track: press maps to one of 20 bars ok"
                     : "note track: WRONG press mapping")
        // The playhead is a bar index, never a separate x coordinate. A
        // finished recording reports 20 played bars but there is no 20th
        // column, so the clamp has to hold it inside the wave.
        let half = RecordingBars.bar(for: 0.5)
        lines.append(RecordingBars.head(0) == 0
                     && RecordingBars.head(half) == half
                     && RecordingBars.head(20) == 19
                     && RecordingBars.head(-1) == 0
                     ? "note track: playhead is one of the 20 bars ok"
                     : "note track: WRONG playhead index")

        // Dragging the editor must be absolute and idempotent: the same
        // pointer position always gives the same origin, so moving the
        // window cannot feed back into the next event and make it shimmer.
        let press = NSPoint(x: 500, y: 400)
        let start = NSPoint(x: 100, y: 200)
        let screen = NSPoint(x: 530, y: 430)
        let once = NoteDrag.origin(start: start, startScreen: press, screen: screen)
        let twice = NoteDrag.origin(start: start, startScreen: press, screen: screen)
        lines.append(once.x == 130 && once.y == 230 && once == twice
                     ? "note drag: absolute idempotent origin ok"
                     : "note drag: WRONG origin \(once)")

        // A stray press outside the panel must not finish a recording. The
        // old handler stopped and adopted the voice on dismissal; that let
        // a click on the desk decide a voice was over.
        lines.append(RecordingPanelDoor.open(requested: false, recording: true)
                     && !RecordingPanelDoor.open(requested: false, recording: false)
                     && RecordingPanelDoor.open(requested: true, recording: false)
                     ? "note panel: a live recording cannot be closed by a click outside ok"
                     : "note panel: WRONG dismissal rule")

        // The notes pill: a rope that fits on one page has no pill, even
        // when one of its three cards carries a recording. It comes back
        // for a second page, and stays while a filter is narrowing the
        // line so the switch that narrowed it can still be reached.
        lines.append(!PagerVisibility.shows(shown: 3, matching: 3,
                                            narrows: false, searching: false)
                     && PagerVisibility.shows(shown: 3, matching: 9,
                                              narrows: false, searching: false)
                     && PagerVisibility.shows(shown: 1, matching: 1,
                                              narrows: true, searching: false)
                     && PagerVisibility.shows(shown: 0, matching: 0,
                                              narrows: false, searching: true)
                     ? "note filter: one page needs no pill ok"
                     : "note filter: WRONG pill visibility")

        // Three colours on the rope have to be three dots. The white cards
        // wear the system colour, which a compactMap used to throw away —
        // seven white, one yellow and one red note drew only two dots.
        let worn: [NoteTint?] = [.blue, nil, .red, .blue, .green]
        let dots = NoteTintFilter.dots(worn)
        lines.append(dots == [.system, .red, .green, .blue]
                     && NoteTintFilter.available([nil, nil]) == [.system]
                     ? "note filter: system colour is a dot, only colours in use ok"
                     : "note filter: WRONG dots \(dots)")

        // One colour in use is no choice at all: no dots, no dead switch.
        lines.append(NoteTintFilter.dots([nil, nil, nil]).isEmpty
                     && NoteTintFilter.dots([.red, .red]).isEmpty
                     && NoteTintFilter.dots([]).isEmpty
                     ? "note filter: one colour draws no dots ok"
                     : "note filter: WRONG single-colour dots")

        // The line that was reported: seven white notes, one yellow and one
        // red. Three colours in use, so the pill has to draw three dots.
        let realLine: [NoteTint?] = [nil, nil, nil, nil, nil, nil, nil, .yellow, .red]
        lines.append(NoteTintFilter.dots(realLine) == [.system, .yellow, .red]
                     ? "note filter: 7 white + 1 yellow + 1 red draws 3 dots ok"
                     : "note filter: WRONG reported line \(NoteTintFilter.dots(realLine))")

        // Several colours at once are a union; the voice switch is a
        // separate question and the two are ANDed. These are the three
        // cases described by hand: two colours plus a voice, two colours
        // alone, and a voice alone.
        func keeps(_ tint: NoteTint?, _ voice: Bool,
                   _ colours: Set<NoteTintChoice>, _ voiceOnly: Bool) -> Bool {
            NoteTintFilter.keeps(tint: tint, hasVoice: voice,
                                 colours: colours, voiceOnly: voiceOnly)
        }
        let two: Set<NoteTintChoice> = [.red, .system]
        lines.append(keeps(.red, true, two, true)
                     && keeps(nil, true, two, true)
                     && !keeps(.blue, true, two, true)
                     && !keeps(.red, false, two, true)
                     && keeps(.red, false, two, false)
                     && !keeps(.blue, false, two, false)
                     && keeps(.blue, true, [], true)
                     && !keeps(.blue, false, [], true)
                     && keeps(.blue, false, [], false)
                     ? "note filter: colours OR, colour and voice AND ok"
                     : "note filter: WRONG keep rule")

        // The pill is measured against the whole line. `pillDepth` has no
        // page argument at all, so a page cannot reach it; the checks pin
        // the cap that keeps the capsule inside the notes panel even for
        // the tallest note, and leave clipboard pictures uncapped.
        let ground = Layout.pillDepth(for: .notes, line: [80, 96, 110])
        let tallest = Layout.pillDepth(for: .notes, line: [400])
        let pillCentre = Layout.pillY(
            ropeY: Layout.ropeY(x: 855, width: 1710), depth: tallest)
        lines.append(ground == 110
                     && tallest == NoteCardLayout.maxHeight + 2 * Frame.inset
                     && Layout.pillDepth(for: .clipboard, line: [140, 300]) == 300
                     && pillCentre + 18 < Layout.notesDepth
                     ? "note pill: whole line sets the ground, tallest note still fits ok"
                     : "note pill: WRONG ground \(ground) / centre \(pillCentre)")

        let legacy = Data(#"{"text":"旧便签"}"#.utf8)
        let old = try? JSONDecoder().decode(Note.self, from: legacy)
        lines.append(old?.text == "旧便签" && old?.recording == nil
                     ? "note recording: legacy note opens ok"
                     : "note recording: WRONG legacy note failed to open")

        // Printed rather than asserted: this answer belongs to macOS, and
        // it is the first thing to look at when no prompt ever appeared.
        // `denied` means the system was asked before and will not ask again.
        lines.append("note recording: microphone state \(MicrophonePermission.state.rawValue)")

        return lines.joined(separator: "\n")
    }
}
