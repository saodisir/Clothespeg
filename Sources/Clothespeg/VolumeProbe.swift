import AVFoundation
import CoreMedia
import Foundation

/// Is the voice quiet because it was recorded quiet, or because playback
/// turned it down? Decode the file itself and measure it, rather than asking
/// either half of the chain to describe the other.
enum VolumeProbe {
    static func run() -> String {
        var lines = ["volume probe: inputMuted=\(AVAudioApplication.shared.isInputMuted)"]
        let names = ((try? FileManager.default.contentsOfDirectory(
            atPath: RecordingStore.folder.path)) ?? [])
            .filter { $0.hasSuffix(".m4a") }
        lines.append("volume probe: \(names.count) existing file(s)")
        for name in names.prefix(4) {
            lines.append(contentsOf: analyse(RecordingStore.url(for: name), name: name))
        }
        // Ask the player's own path to build the loud copy, then measure
        // that copy. Deleting it first makes sure the decode/write branch
        // really ran rather than reading a file left by an earlier probe.
        if let first = names.first {
            PlaybackGain.discard(first)
            let sample = Note.Recording(name: first, seconds: 2, bars: [])
            let boosted = PlaybackGain.preparedURL(for: sample)
            lines.append("volume probe: playback opens \(boosted.lastPathComponent)")
            lines.append(contentsOf: analyse(boosted, name: "boosted"))
        }
        lines.append(contentsOf: recordAndAnalyse())
        return lines.joined(separator: "\n")
    }

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    /// A fresh two seconds, so the metering numbers and the bytes written to
    /// disk can be compared on the very same recording.
    private static func recordAndAnalyse() -> [String] {
        var out = ["volume probe: fresh recording"]
        do {
            try RecordingStore.prepare()
            let url = RecordingStore.folder
                .appendingPathComponent("volprobe-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                out.append("  record() returned false")
                return out
            }
            let box = Levels()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                recorder.updateMeters()
                box.add(recorder.peakPower(forChannel: 0))
            }
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            timer.invalidate()
            recorder.stop()
            let levels = box.snapshot()
            if let low = levels.min(), let high = levels.max() {
                out.append("  meter peakPower \(String(format: "%.1f", low)) .. \(String(format: "%.1f", high)) dB")
            }
            out.append(contentsOf: analyse(url, name: "fresh"))
            // The same file through the player's own path. This is the level
            // the person actually hears, not the level on disk.
            let made = Note.Recording(name: url.lastPathComponent, seconds: 2, bars: [])
            PlaybackGain.discard(made.name)
            let boosted = PlaybackGain.preparedURL(for: made)
            out.append(contentsOf: analyse(boosted, name: "fresh boosted"))
            PlaybackGain.discard(made.name)
            try? FileManager.default.removeItem(at: url)
        } catch {
            out.append("  \(error.localizedDescription)")
        }
        return out
    }

    private static func analyse(_ url: URL, name: String) -> [String] {
        var out = ["volume probe: \(name.prefix(8)) "
                   + "\((try? Data(contentsOf: url))?.count ?? 0) bytes"]
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            out.append("  no audio track")
            return out
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            out.append("  player volume=\(player.volume) "
                       + "duration=\(String(format: "%.2f", player.duration)) "
                       + "channels=\(player.numberOfChannels) "
                       + "rate=\(player.settings[AVSampleRateKey] ?? "?")")
        } catch {
            out.append("  player error \(error.localizedDescription)")
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else {
            out.append("  reader unavailable")
            return out
        }
        reader.add(output)
        guard reader.startReading() else {
            out.append("  reader failed \(reader.error?.localizedDescription ?? "")")
            return out
        }
        var peak: Float = 0
        var sum: Double = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            bytes.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                               dataLength: length,
                                               destination: raw.baseAddress!)
            }
            bytes.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Float.self)
                for index in 0..<min(samples.count, length / 4) {
                    let value = samples[index]
                    peak = max(peak, abs(value))
                    sum += Double(value) * Double(value)
                    count += 1
                }
            }
        }
        let rms = sqrt(sum / Double(max(1, count)))
        out.append("  pcm peak=\(String(format: "%.4f", peak)) (\(decibels(Double(peak))) dBFS) "
                   + "rms=\(String(format: "%.4f", rms)) (\(decibels(rms)) dBFS) "
                   + "samples=\(count)")
        return out
    }

    private static func decibels(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f", 20 * log10(value)) : "-inf"
    }

    private final class Levels: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Float] = []
        func add(_ value: Float) { lock.lock(); values.append(value); lock.unlock() }
        func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return values }
    }
}
