import AppKit
import AVFoundation
import Darwin
import Foundation

/// A three-second look at the numbers the recording wave is made from.
///
/// Runs on the thread that starts it, with no Swift concurrency in the way:
/// if the waveform is flat here, the microphone levels are the problem; if
/// the wave moves here but not in the editor, the editor's timer is.
enum RecordingProbe {
    /// A pause has to leave the clock still, leave the silence out of the
    /// wave, and still write a file that opens. These are AVAudioRecorder's
    /// answers, asked before a button is built on top of them.
    static func runPause() -> String {
        var out = ["pause probe: permission \(MicrophonePermission.state.rawValue)"]
        guard MicrophonePermission.isGranted else {
            out.append("pause probe: no permission, stopped")
            return out.joined(separator: "\n")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            try RecordingStore.prepare()
            // One: record, pause, resume, stop.
            let url = RecordingStore.folder
                .appendingPathComponent("pauseprobe-\(UUID().uuidString).m4a")
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                out.append("pause probe: record() returned false")
                return out.joined(separator: "\n")
            }
            spin(0.8)
            rec.updateMeters()
            out.append("  one: before pause t=\(clock(rec.currentTime)) "
                       + "db=\(db(rec.peakPower(forChannel: 0)))")
            rec.pause()
            let pausedAt = rec.currentTime
            spin(1.2)
            rec.updateMeters()
            out.append("  one: paused 1.20s, t=\(clock(rec.currentTime)) "
                       + "moved=\(clock(rec.currentTime - pausedAt)) "
                       + "db=\(db(rec.peakPower(forChannel: 0)))")
            out.append("  one: resume returned \(rec.record())")
            let after = Samples()
            let meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                rec.updateMeters()
                after.add(db: rec.peakPower(forChannel: 0), time: rec.currentTime)
            }
            spin(0.8)
            meter.invalidate()
            let (_, afterDb, _) = after.snapshot()
            out.append("  one: after resume t=\(clock(rec.currentTime)) db="
                       + afterDb.prefix(8).map { db($0) }.joined(separator: ","))
            rec.stop()
            out.append("  one: file \(describe(url))")
            try? FileManager.default.removeItem(at: url)

            // Two: press stop while paused. That file has to open too.
            let short = RecordingStore.folder
                .appendingPathComponent("pauseprobe-\(UUID().uuidString).m4a")
            let rec2 = try AVAudioRecorder(url: short, settings: settings)
            guard rec2.record() else {
                out.append("  two: record() returned false")
                return out.joined(separator: "\n")
            }
            spin(0.6)
            rec2.pause()
            out.append("  two: paused at t=\(clock(rec2.currentTime))")
            rec2.stop()
            out.append("  two: file \(describe(short))")
            try? FileManager.default.removeItem(at: short)
        } catch {
            out.append("  \(error.localizedDescription)")
        }
        return out.joined(separator: "\n")
    }

    private static func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func clock(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }

    private static func db(_ value: Float) -> String {
        String(format: "%.1f", value)
    }

    private static func describe(_ url: URL) -> String {
        let bytes = (try? Data(contentsOf: url))?.count ?? 0
        let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? -1
        return "\(bytes) bytes, duration=\(clock(duration))s"
    }

    static func run() -> String {
        var lines = ["rec probe: main=\(onMain())",
                     "rec probe: permission \(MicrophonePermission.state.rawValue)"]
        guard MicrophonePermission.isGranted else {
            lines.append("rec probe: no permission, stopped")
            return lines.joined(separator: "\n")
        }
        do {
            try RecordingStore.prepare()
            let url = RecordingStore.folder
                .appendingPathComponent("probe-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                lines.append("rec probe: record() returned false")
                return lines.joined(separator: "\n")
            }

            let samples = Samples()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                recorder.updateMeters()
                samples.add(db: recorder.peakPower(forChannel: 0),
                            time: recorder.currentTime)
            }
            let started = Date()
            let deadline = started.addingTimeInterval(3)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            timer.invalidate()
            let wall = Date().timeIntervalSince(started)
            let currentTime = recorder.currentTime
            recorder.stop()
            try? FileManager.default.removeItem(at: url)

            let (fired, dbs, times) = samples.snapshot()
            lines.append("rec probe: wall \(String(format: "%.2f", wall))s, "
                         + "currentTime \(String(format: "%.2f", currentTime))s, "
                         + "timer fired \(fired)")
            if let low = dbs.min(), let high = dbs.max() {
                lines.append("rec probe: peakPower dB \(String(format: "%.1f", low)) .. \(String(format: "%.1f", high))")
            }
            let mapped = dbs.map(RecordingBars.level)
            if let low = mapped.min(), let high = mapped.max() {
                lines.append("rec probe: mapped levels \(low) .. \(high)")
            }
            let bars = RecordingBars.from(mapped)
            lines.append("rec probe: bars \(bars)")
            lines.append("rec probe: bar spread \((bars.max() ?? 0) - (bars.min() ?? 0))")
            lines.append("rec probe: dB first 12 "
                         + dbs.prefix(12).map { String(format: "%.0f", $0) }.joined(separator: ","))
            lines.append("rec probe: time first 12 "
                         + times.prefix(12).map { String(format: "%.2f", $0) }.joined(separator: ","))
        } catch {
            lines.append("rec probe: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    /// `NoteRecorder.start()` used to be a nonisolated async function: after
    /// its permission await, Swift ran it on a cooperative-pool thread whose
    /// run loop nobody drives, so `Timer.scheduledTimer` never fired. This
    /// reproduces that hop on its own, without touching the recorder.
    static func runConcurrency() -> String {
        let lines = Lines()
        let done = Done()
        Task { @MainActor in
            await mimicStart(lines)
            done.set()
        }
        wait(done, seconds: 10, lines: lines, what: "concurrency task")
        return lines.snapshot().joined(separator: "\n")
    }

    private static func mimicStart(_ lines: Lines) async {
        let before = onMain()
        _ = await MicrophonePermission.request()
        lines.add("concurrency: before await main=\(before), after await main=\(onMain())")
        lines.add("concurrency: a timer scheduled here would sit on an undriven run loop")
    }

    /// Three seconds through the real `NoteRecorder`: the meter has to tick,
    /// the clock has to move, and the note has to come back with the whole
    /// duration and a wave that has a shape.
    static func runThroughRecorder() -> String {
        let lines = Lines()
        let done = Done()
        Task { @MainActor in
            let ok = await NoteRecorder.shared.start()
            lines.add("rec app: start ok=\(ok) error=\(NoteRecorder.shared.lastError ?? "none")")
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let levels = NoteRecorder.shared.levels
                lines.add("rec app: elapsed=\(NoteRecorder.shared.elapsed)s "
                          + "bars=\(levels.count) spread=\((levels.max() ?? 0) - (levels.min() ?? 0)) "
                          + "last=\(levels.last ?? 0)")
            }
            let made = NoteRecorder.shared.stop()
            lines.add("rec app: stop seconds=\(made?.seconds ?? -1) bars=\(made?.bars ?? [])")
            if let made { RecordingStore.discard(made.name) }
            done.set()
        }
        wait(done, seconds: 25, lines: lines, what: "recorder task")
        return lines.snapshot().joined(separator: "\n")
    }

    /// The product's own pause button: a held recording must not gain a
    /// strip of -120 dB silence, and the wave must carry on where it left
    /// off when the person comes back.
    static func runPauseThroughRecorder() -> String {
        let lines = Lines()
        let done = Done()
        Task { @MainActor in
            let rec = NoteRecorder.shared
            let ok = await rec.start()
            lines.add("pause app: start ok=\(ok)")
            try? await Task.sleep(nanoseconds: 600_000_000)
            lines.add("pause app: before pause t=\(rec.elapsed)s bars=\(rec.levels)")
            rec.pause()
            let frozen = rec.levels
            let frozenCount = rec.sampleCount
            try? await Task.sleep(nanoseconds: 900_000_000)
            lines.add("pause app: held isPaused=\(rec.isPaused) "
                      + "wave unchanged=\(frozen == rec.levels) "
                      + "samples frozen=\(rec.sampleCount == frozenCount) "
                      + "t=\(rec.elapsed)s")
            rec.resume()
            try? await Task.sleep(nanoseconds: 600_000_000)
            lines.add("pause app: resumed isPaused=\(rec.isPaused) "
                      + "meter restarted=\(rec.sampleCount > frozenCount) "
                      + "samples=\(rec.sampleCount) t=\(rec.elapsed)s")
            let made = rec.stop()
            lines.add("pause app: stop seconds=\(made?.seconds ?? -1) "
                      + "bars=\(made?.bars ?? [])")
            if let made { RecordingStore.discard(made.name) }
            done.set()
        }
        wait(done, seconds: 20, lines: lines, what: "paused recorder task")
        return lines.snapshot().joined(separator: "\n")
    }

    /// The card's whole wave is a slider. Arithmetic can say which of the
    /// twenty bars a press names, but only the real player can say that a
    /// boosted WAV can be sought at all, and that the voice actually starts
    /// at the pressed moment rather than merely colouring that far.
    static func runSeek() -> String {
        let lines = Lines()
        let done = Done()
        Task { @MainActor in
            let names = (try? FileManager.default
                .contentsOfDirectory(atPath: RecordingStore.folder.path))?
                .filter { $0.hasSuffix(".m4a") } ?? []
            guard let name = names.first else {
                lines.add("seek probe: no recording on disk, skipped")
                done.set()
                return
            }
            let recording = Note.Recording(
                name: name,
                seconds: 0,
                bars: Array(repeating: 50, count: RecordingBars.count))
            let playable = PlaybackGain.preparedURL(for: recording)
            let duration = (try? AVAudioPlayer(contentsOf: playable))?.duration ?? 0
            lines.add("seek probe: file=\(name) playable=\(playable.lastPathComponent) "
                      + "duration=\(String(format: "%.2f", duration))s")
            guard duration > 0.5 else {
                lines.add("seek probe: WRONG playable file will not open")
                done.set()
                return
            }
            let player = NotePlayer.shared
            player.seek(recording, to: 0)
            let atStart = (player.playedBars, player.elapsed)
            player.seek(recording, to: 0.5)
            let middle = (player.playedBars, player.elapsed)
            player.seek(recording, to: 0.9)
            let nearEnd = (player.playedBars, player.elapsed)
            player.stop()
            lines.add("seek probe: f=0.00 bars=\(atStart.0) elapsed=\(atStart.1)")
            lines.add("seek probe: f=0.50 bars=\(middle.0) elapsed=\(middle.1)")
            lines.add("seek probe: f=0.90 bars=\(nearEnd.0) elapsed=\(nearEnd.1)")
            let expectedMiddle = Int(duration * 0.5)
            let expectedEnd = Int(duration * 0.9)
            lines.add(atStart.0 == 0 && middle.0 == 10 && nearEnd.0 == 18
                      && abs(middle.1 - expectedMiddle) <= 1
                      && abs(nearEnd.1 - expectedEnd) <= 1
                      ? "seek probe: a press moves the voice ok"
                      : "seek probe: WRONG press did not move the player")
            done.set()
        }
        wait(done, seconds: 12, lines: lines, what: "seek task")
        return lines.snapshot().joined(separator: "\n")
    }

    /// The press-to-seek chain with a real mouse event against a real
    /// GrabView. The arithmetic can be right and the press can still land
    /// somewhere else — this is the probe that walks the whole chain.
    static func runHit() -> String {
        var out: [String] = []
        let paperHeight: CGFloat = 140
        let bounds = NSRect(
            x: 0, y: 0,
            width: NoteCardLayout.width + Frame.inset * 2,
            height: paperHeight + Frame.inset * 2)
        let view = GrabView(frame: bounds)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.hasRecording = true
        view.paperHeight = paperHeight
        view.isRinging = { false }
        var sought: [Double] = []
        var plays = 0
        view.onSeekRecording = { sought.append($0) }
        view.onPlayRecording = { plays += 1 }

        let bandTop = paperHeight - NoteCardLayout.bottomPad
            - NoteCardLayout.captionHeight - NoteCardLayout.recordingHeight
        let paperY = bandTop + NoteCardLayout.recordingHeight / 2

        func press(_ paperX: CGFloat, number: Int) {
            let point = NSPoint(x: paperX + Frame.inset,
                                y: bounds.height - Frame.inset - paperY)
            guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: 1) else { return }
            guard let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: 0) else { return }
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }

        let track = NoteCardLayout.recordingTrackMinX
        let width = NoteCardLayout.recordingTrackWidth
        press(NoteCardLayout.recordingSidePad + 4, number: 1)
        press(track + width * 0.25, number: 2)
        press(track + width * 0.5, number: 3)
        press(track + width * 0.9, number: 4)
        press(NoteCardLayout.width - NoteCardLayout.recordingSidePad, number: 5)

        out.append("hit probe: capsule plays=\(plays) seeks=\(sought.count)")
        out.append("hit probe: fractions="
                   + sought.map { String(format: "%.2f", $0) }.joined(separator: ","))
        let ok = plays == 1 && sought.count == 4
            && abs(sought[0] - 0.25) < 0.02
            && abs(sought[1] - 0.5) < 0.02
            && abs(sought[2] - 0.9) < 0.02
            && sought[3] > 0.99
        out.append(ok ? "hit probe: a press on the wave reaches the player ok"
                      : "hit probe: WRONG press did not reach the player")
        return out.joined(separator: "\n")
    }

    private static func wait(_ done: Done, seconds: Double, lines: Lines, what: String) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done.isDone && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if !done.isDone { lines.add("\(what) never returned within \(Int(seconds))s") }
    }

    /// `Thread.isMainThread` is deliberately unavailable from async contexts
    /// in Swift 6; the C predicate asks the same question without an opinion
    /// about where it is called from.
    private static func onMain() -> Bool { pthread_main_np() != 0 }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = 0
        private var dbs: [Float] = []
        private var times: [Double] = []

        func add(db: Float, time: Double) {
            lock.lock()
            defer { lock.unlock() }
            fired += 1
            dbs.append(db)
            times.append(time)
        }

        func snapshot() -> (Int, [Float], [Double]) {
            lock.lock()
            defer { lock.unlock() }
            return (fired, dbs, times)
        }
    }
}
