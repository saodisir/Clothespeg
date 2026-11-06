import AppKit
import AVFAudio
import AVFoundation
import Darwin

/// A one-shot look at the microphone gate from *inside the app process*.
///
/// TCC answers for the responsible process. Run the executable straight from a
/// shell and it answers for Terminal, which often already has the microphone;
/// the same binary launched by Finder or LaunchServices answers for the app.
/// That difference is exactly why "the self-test says granted" and "the app
/// says denied" can both be true, so this probe is only meaningful when it is
/// started with `open --env ... -a Clothespeg.app`.
enum MicrophoneProbe {
    static func run() -> String {
        let environment = ProcessInfo.processInfo
        let bundle = Bundle.main

        let audio: String = {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return "granted"
            case .denied: return "denied"
            case .undetermined: return "undetermined"
            @unknown default: return "unknown"
            }
        }()
        let capture: String = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .notDetermined: return "notDetermined"
            case .restricted: return "restricted"
            @unknown default: return "unknown"
            }
        }()

        var lines = [
            "mic probe: pid \(environment.processIdentifier) ppid \(getppid())",
            "mic probe: bundle \(bundle.bundleIdentifier ?? "none")",
            "mic probe: path \(bundle.bundlePath)",
            "mic probe: macOS \(environment.operatingSystemVersionString)",
            "mic probe: usage description \(bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") ?? "MISSING")",
            "mic probe: activation policy \(NSApp.activationPolicy().rawValue), active \(NSApp.isActive)",
            "mic probe: AVAudioApplication \(audio)",
            "mic probe: AVCaptureDevice \(capture)",
            "mic probe: hasAsked \(UserDefaults.standard.bool(forKey: "askedForMicrophone"))",
        ]
        // The app is not sandboxed, so it can read the table that a shell in
        // a sandbox cannot. A stale "denied" row here is the difference
        // between "macOS will ask" and "macOS already has an answer".
        let listed = tccList().split(separator: "\n").map(String.init)
        lines.append("mic probe: tccutil list Microphone (\(listed.count) lines)")
        lines.append(contentsOf: listed.prefix(20).map { "mic probe:   \($0)" })
        return lines.joined(separator: "\n")
    }

    /// Puts the real question to macOS from this process and appends the
    /// answer. Kept out of `run()` so the ordinary probe never spends the one
    /// prompt the system is willing to show.
    static func ask(reportPath path: String) {
        let answer = Answer()
        let started = Date()
        NSApp.activate(ignoringOtherApps: true)
        let active = NSApp.isActive
        AVAudioApplication.requestRecordPermission { granted in
            let waited = Date().timeIntervalSince(started)
            answer.set("granted=\(granted) after \(String(format: "%.2f", waited))s, "
                       + "state=\(MicrophonePermission.state.rawValue), active=\(active)")
        }
        // A callback that comes straight back means macOS already had an
        // answer and never put a dialog up. A slow one means the user was
        // asked. Pumping the run loop (rather than blocking on a semaphore)
        // leaves the main queue free for the answer.
        let deadline = Date().addingTimeInterval(150)
        while answer.get() == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        append(["mic probe: request " + (answer.get() ?? "no answer within 150s (dialog left unanswered)"),
                "mic probe: recorder \(recordCheck())"], to: path)
    }

    /// Permission being granted is not the same as Core Audio actually
    /// handing over samples; the hardened-runtime entitlement gates that too.
    private static func recordCheck() -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clothespeg-mic-probe-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            let started = recorder.record()
            let until = Date().addingTimeInterval(0.4)
            while Date() < until {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            let result = "started=\(started), recording=\(recorder.isRecording), "
                + "currentTime=\(String(format: "%.2f", recorder.currentTime))s"
            if started { recorder.stop() }
            try? FileManager.default.removeItem(at: url)
            return result
        } catch {
            try? FileManager.default.removeItem(at: url)
            return "error=\(error.localizedDescription)"
        }
    }

    private static func append(_ lines: [String], to path: String) {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let text = existing + (existing.isEmpty ? "" : "\n") + lines.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The completion handler may arrive on any thread, so the one value it
    /// hands back is guarded rather than a plain captured variable.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return text }
    }

    private static func tccList() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["list", "Microphone"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return "tccutil failed: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "tccutil exit=\(task.terminationStatus), no output" : text
    }
}
