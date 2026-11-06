import AVFoundation
import AppKit
import CoreMedia
import SwiftUI

/// Where a note's voice lives.
///
/// The note itself stays in `Notes.json`; only a file name is written there,
/// so a moved attic or a restored backup cannot leave a note pointing at a
/// path that no longer exists. This folder sits beside that file and is made
/// with the same permissions the attic uses.
enum RecordingStore {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("Clothespeg/Recordings", isDirectory: true)
    }()

    static func url(for name: String) -> URL { folder.appendingPathComponent(name) }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// One note's file, when the note lets go of it. A missing file is not an
    /// error: the note may have been discarded twice, or restored from a
    /// backup that never carried the recording. The loud copy in Caches is
    /// a derivative, so it goes at the same moment.
    static func discard(_ name: String) {
        PlaybackGain.discard(name)
        try? FileManager.default.removeItem(at: url(for: name))
    }
}

/// The bars on a card, and the arithmetic that makes them. Kept out of the
/// recorder so the self-test can ask it without a microphone, a window or
/// an actor to stand in.
enum RecordingBars {
    static let count = 20

    /// One fixed ruler for every recording: -70 dB, the noise floor of a
    /// desk microphone in a quiet room, is 0; -10 dB, a loud voice close to
    /// it, is 100. Nothing here is scaled per recording. A quiet memo is a
    /// low wave, a loud one a tall one, and two cards can be compared by eye.
    ///
    /// The earlier version stretched every recording across its own range.
    /// Measured on this Mac, nine seconds of even speech (-25..-29 dB) and
    /// fifteen seconds with a -2 dB knock both came back as bars spanning
    /// 18..100: two different sounds wearing the same shape.
    static func level(_ db: Float) -> Int {
        min(100, max(0, Int((db + 70) / 60 * 100)))
    }

    /// A bar is one 0.1 s reading, read off the fixed ruler above. For the
    /// first two seconds the wave grows one bar at a time; after that the
    /// whole recording is shared between twenty equal slices of time and a
    /// bar is the loudest moment in its own slice — a short word or a knock
    /// is what the eye looks for. A pause stays low, a shout stays high, an
    /// empty recording draws a low flat line, and nothing is ever stretched
    /// to fill the card.
    static func from(_ samples: [Int]) -> [Int] {
        guard !samples.isEmpty else { return empty }
        if samples.count < count {
            return samples + Array(repeating: 0, count: count - samples.count)
        }
        return (0..<count).map { index in
            let start = index * samples.count / count
            let end = min(samples.count, max(start + 1, (index + 1) * samples.count / count))
            return samples[start..<end].max() ?? 0
        }
    }

    static var empty: [Int] { Array(repeating: 0, count: count) }

    /// A press anywhere on the card's wave names one of the twenty bars.
    /// Keeping the mapping here lets the self-test pin it down without a
    /// player or a mouse.
    static func bar(for fraction: Double) -> Int {
        min(count - 1, max(0, Int(fraction * Double(count))))
    }

    /// The one bar that wears the playhead. `playedBars` can reach `count`
    /// when a recording finishes, but there is no bar at that index. The
    /// head is an index, never an x coordinate: a line drawn at
    /// `width * played / count` used to land half a column left of the bar
    /// it belonged to and read as a twenty-first, taller bar.
    static func head(_ played: Int) -> Int {
        min(count - 1, max(0, played))
    }

    /// The same scale the panel and the card both use, so what was heard in
    /// the editor is the shape that lands on the note.
    static func height(_ level: Int) -> CGFloat {
        let normalised = (CGFloat(min(100, max(0, level))) - 10) / 90
        // Thinner bars with a little more room between the floor and the
        // ceiling: 2..16pt rather than 3..14pt. The ruler itself is
        // unchanged — only how far apart its ends are drawn.
        return 2 + max(0, min(1, normalised)) * 14
    }
}

enum AudioClock {
    static func label(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A voice memo is recorded from a microphone, not mastered like an alert
/// sound: measured here, a healthy one peaks around -25 dBFS where a system
/// sound sits close to 0 dBFS. `AVAudioPlayer.volume` is already 1.0 and
/// cannot go higher, so a quiet file is made louder before it is played.
///
/// The original recording is never touched. A plain WAV copy with the gain
/// baked in lives in Caches under the recording's own name, can be rebuilt
/// at any time, and is thrown away with the recording. Old notes get the
/// same treatment as new ones because the gain is decided at play time.
enum PlaybackGain {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clothespeg/Playback", isDirectory: true)
    }()

    /// Peak target with headroom. Bringing a memo to -6 dBFS puts it beside
    /// the system's own sounds without leaving the converter anywhere to
    /// clip.
    static let targetDb: Float = -6
    /// Never raise a file by more than this: a recording of nothing but room
    /// tone must not come back as a wall of hiss.
    static let ceilingDb: Float = 24

    static func url(for name: String) -> URL {
        folder.appendingPathComponent(name + ".wav")
    }

    static func discard(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    static func decibels(_ peak: Float) -> Float {
        peak > 0 ? Float(20 * log10(Double(peak))) : -160
    }

    /// Pure arithmetic, so the self-test can ask it without decoding a file.
    static func gainDb(peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return min(ceilingDb, max(0, targetDb - decibels(peak)))
    }

    static func gain(peak: Float) -> Float {
        Float(pow(10.0, Double(gainDb(peak: peak) / 20)))
    }

    /// The URL the player should open. Any failure along the way hands back
    /// the original file: a quiet voice is better than no voice at all.
    static func preparedURL(for recording: Note.Recording) -> URL {
        let original = RecordingStore.url(for: recording.name)
        guard RecordingStore.exists(recording.name) else { return original }
        let cached = url(for: recording.name)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let samples = decode(original), !samples.isEmpty else { return original }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let boost = gainDb(peak: peak)
        // Under a decibel of gain is not worth a second file, and a file
        // that is already loud must be left exactly as it was recorded.
        guard boost >= 1 else { return original }
        do {
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            try wav(samples, gain: gain(peak: peak)).write(to: cached, options: .atomic)
            diagLog("Playback gain: \(recording.name.prefix(8)) peak "
                    + "\(String(format: "%.1f", decibels(peak))) dBFS "
                    + "+\(String(format: "%.1f", boost)) dB")
            return cached
        } catch {
            diagLog("Playback gain could not be written: \(error.localizedDescription)")
            return original
        }
    }

    /// Float32 PCM at the rate the recorder writes, so the WAV header below
    /// can state 44100 Hz without a conversion step in between.
    private static func decode(_ url: URL) -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else {
            return nil
        }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            bytes.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                               dataLength: length,
                                               destination: raw.baseAddress!)
            }
            let frames = length / 4
            bytes.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for index in 0..<frames { samples.append(floats[index]) }
            }
        }
        return samples.isEmpty ? nil : samples
    }

    /// A 16-bit mono WAV, written by hand so the bytes the player reads are
    /// the bytes the gain was applied to. The gain is chosen from the peak,
    /// so the amplified peak lands at -6 dBFS and the clamp is only a guard.
    private static func wav(_ samples: [Float], gain multiplier: Float) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44 + samples.count * 2)
        func le16(_ value: UInt16) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8(value >> 8))
        }
        func le32(_ value: UInt32) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8((value >> 8) & 0xff))
            bytes.append(UInt8((value >> 16) & 0xff))
            bytes.append(UInt8((value >> 24) & 0xff))
        }
        bytes.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + samples.count * 2))
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("fmt ".utf8))
        le32(16)
        le16(1)                       // linear PCM
        le16(1)                       // mono
        le32(44100)                   // the recorder's rate
        le32(44100 * 2)              // byte rate
        le16(2)                       // block align
        le16(16)                      // bits per sample
        bytes.append(contentsOf: Array("data".utf8))
        le32(UInt32(samples.count * 2))
        for sample in samples {
            let scaled = max(-1, min(1, sample * multiplier))
            let value = Int16(clamping: Int32(scaled * 32767))
            le16(UInt16(bitPattern: value))
        }
        return Data(bytes)
    }
}

private enum NoteAudioError: Error { case cannotRecord }

/// The one recorder. There is one editor at a time and one note being
/// written in it, so a second recording cannot be in progress when the
/// first is started. All of its mutable state lives on the main thread.
final class NoteRecorder: ObservableObject, @unchecked Sendable {
    static let shared = NoteRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Int = 0
    /// Bars for the panel while recording, and the same numbers handed to
    /// the note when it stops — what was heard is what the card draws.
    @Published private(set) var levels: [Int] = []
    @Published var lastError: String?
    /// The same recording, held open. `isRecording` stays true across a
    /// pause: closing the panel, cancelling the edit and the stop button all
    /// still have one live recording to answer to.
    @Published private(set) var isPaused = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentName: String?
    private var samples: [Int] = []

    private init() {}

    /// Diagnostic only: a pause must not add readings, and a resume must.
    /// Unlike `levels`, this answer does not depend on how loud the room is.
    var sampleCount: Int { samples.count }

    /// Both the first start and every resume use the same timer. `.common`,
    /// not the default mode: a popover tracking a press or a scroll runs the
    /// loop in `.eventTracking`, where a `.default` timer stops dead.
    private func armMeter() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    /// Measured on this Mac: `AVAudioRecorder.currentTime` stands still while
    /// paused, `record()` resumes the same file, and a `stop()` straight out
    /// of a pause still writes a file that opens. `updateMeters()` however
    /// reports -120 dB while paused, so the meter must stop sampling or the
    /// pause becomes a strip of invented silence in the wave.
    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
        meterTimer?.invalidate()
        meterTimer = nil
        diagLog("Recording paused: t=\(elapsed)s samples=\(samples.count)")
    }

    func resume() {
        guard isRecording, isPaused else { return }
        guard recorder?.record() == true else { return }
        isPaused = false
        armMeter()
        diagLog("Recording resumed: t=\(elapsed)s samples=\(samples.count)")
    }

    func start() async -> Bool {
        guard !isRecording else { return true }
        lastError = nil
        guard await MicrophonePermission.request() else {
            // A state the page can act on, not only a string: a refusal
            // already recorded by macOS will never show its prompt again,
            // and the recording panel offers the settings pane for it.
            lastError = L("Microphone denied")
            return false
        }
        // This method is not isolated to the main actor. After the first
        // await, Swift runs a nonisolated async function on a cooperative
        // pool thread — measured here as thread number 4, `main=false`.
        // `Timer.scheduledTimer` on such a thread is attached to a run loop
        // nobody runs, so the meter never ticks, the clock never moves and
        // the note ends up with an empty set of bars. Both the recorder and
        // the timer are therefore created explicitly on the main actor.
        return await MainActor.run { () -> Bool in
            diagLog("Recording starting: main=\(Thread.isMainThread)")
            do {
                try RecordingStore.prepare()
                let name = UUID().uuidString + ".m4a"
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
                let rec = try AVAudioRecorder(url: RecordingStore.url(for: name), settings: settings)
                rec.isMeteringEnabled = true
                guard rec.record() else { throw NoteAudioError.cannotRecord }
                recorder = rec
                currentName = name
                samples = []
                elapsed = 0
                levels = RecordingBars.from([])
                isRecording = true
                isPaused = false
                armMeter()
                return true
            } catch {
                diagLog("Recording could not start: \(error.localizedDescription)")
                lastError = L("Recording failed")
                return false
            }
        }
    }

    private func sample() {
        guard let recorder, isRecording, !isPaused else { return }
        recorder.updateMeters()
        // Peak power is decibels below full scale; the scale lives beside
        // `from(_:)` so the panel and the card can never disagree about a
        // level that was heard.
        let db = recorder.peakPower(forChannel: 0)
        elapsed = Int(recorder.currentTime)
        // -120 dB is the "no meter" sentinel AVAudioRecorder reports while
        // paused and on its first frames. Writing it would put a bar of
        // invented silence into the wave.
        guard db > -110 else { return }
        samples.append(RecordingBars.level(db))
        levels = RecordingBars.from(samples)
        if samples.count % 10 == 0 {
            diagLog("Recording meter: t=\(elapsed)s db=\(String(format: "%.1f", db)) "
                    + "samples=\(samples.count) lastBar=\(levels.last ?? 0)")
        }
    }

    /// Ends the recording and hands back the note's description of it. The
    /// file is already on disk; the caller owns it from this moment on.
    func stop() -> Note.Recording? {
        guard isRecording, let recorder, let name = currentName else { return nil }
        meterTimer?.invalidate()
        meterTimer = nil
        let clock = recorder.currentTime
        let seconds = max(1, Int(clock.rounded()))
        recorder.stop()
        let bars = RecordingBars.from(samples)
        diagLog("Recording stopped: currentTime=\(String(format: "%.2f", clock))s "
                + "seconds=\(seconds) samples=\(samples.count) bars=\(bars)")
        self.recorder = nil
        currentName = nil
        isRecording = false
        isPaused = false
        guard RecordingStore.exists(name) else {
            lastError = L("Recording failed")
            return nil
        }
        return Note.Recording(name: name, seconds: seconds, bars: bars)
    }

    /// A window closed, or a recording abandoned. The note keeps nothing and
    /// the file goes with it; a recording already stopped has been handed to
    /// the draft and is not touched here.
    func cancel() {
        meterTimer?.invalidate()
        meterTimer = nil
        if isRecording { recorder?.stop() }
        if let name = currentName { RecordingStore.discard(name) }
        recorder = nil
        currentName = nil
        isRecording = false
        isPaused = false
        samples = []
        levels = []
        elapsed = 0
    }
}

/// The one player. One voice at a time on a line of cards: playing a second
/// note stops the first rather than letting two speak over each other.
final class NotePlayer: ObservableObject, @unchecked Sendable {
    static let shared = NotePlayer()

    @Published private(set) var playingName: String?
    @Published private(set) var playedBars = 0
    @Published private(set) var elapsed = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    private init() {}

    func toggle(_ recording: Note.Recording) {
        if playingName == recording.name { stop(); return }
        stop()
        guard RecordingStore.exists(recording.name) else {
            diagLog("Recording missing: \(recording.name)")
            return
        }
        do {
            let playable = PlaybackGain.preparedURL(for: recording)
            let next = try AVAudioPlayer(contentsOf: playable)
            next.prepareToPlay()
            guard next.play() else { return }
            player = next
            playingName = recording.name
            playedBars = 0
            elapsed = 0
            let ticking = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // The card's progress has to keep moving while a menu or another
            // control is tracking the pointer, same as the recording meter.
            RunLoop.main.add(ticking, forMode: .common)
            timer = ticking
        } catch {
            diagLog("Recording could not play: \(error.localizedDescription)")
        }
    }

    /// The card's whole wave is the slider. A press or a drag names a
    /// position in this recording and the voice starts there; positions are
    /// quantised to the twenty bars, so dragging the length of a card is at
    /// most twenty seeks rather than one per mouse event.
    func seek(_ recording: Note.Recording, to fraction: Double) {
        if playingName != recording.name { toggle(recording) }
        guard let player else { return }
        let bar = RecordingBars.bar(for: fraction)
        guard bar != playedBars else { return }
        let target = player.duration * Double(bar) / Double(RecordingBars.count)
        let ceiling = max(0, player.duration - 0.02)
        player.currentTime = min(ceiling, max(0, target))
        playedBars = bar
        elapsed = Int(player.currentTime)
        diagLog("Recording seek: bar \(bar)/\(RecordingBars.count) "
                + "t=\(String(format: "%.2f", player.currentTime))s")
    }

    private func tick() {
        guard let player, player.isPlaying else { stop(); return }
        let duration = max(player.duration, 0.01)
        let bars = min(RecordingBars.count,
                       Int(player.currentTime / duration * Double(RecordingBars.count)))
        // Only a change worth drawing is published. A card redrawn ten times
        // a second for a progress nobody can see that fast is a card that
        // costs more than it says.
        if bars != playedBars { playedBars = bars }
        let seconds = Int(player.currentTime)
        if seconds != elapsed { elapsed = seconds }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingName = nil
        playedBars = 0
        elapsed = 0
    }
}
