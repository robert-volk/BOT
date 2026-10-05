import AVFoundation
import Speech

/// Long-form listening for meeting notes and the voice journal, using on-device speech recognition.
/// iOS limits one recognition task to about a minute, so this rolls over to a fresh task every ~55 seconds and
/// stitches the text together. Nothing is uploaded: audio is never saved, only the text.
@MainActor
final class MeetingRecorder: ObservableObject {
    enum Kind { case meeting, journal }

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var kind: Kind?
    private(set) var startedAt = Date()

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cycleTimer: Timer?
    private var finalized = ""
    private var partial = ""
    private var generation = 0
    private var onStopPhrase: (() -> Void)?

    // MARK: Control

    func start(kind: Kind, onStopPhrase: @escaping () -> Void) {
        guard !isRecording, let recognizer, recognizer.isAvailable else { return }
        self.kind = kind
        self.onStopPhrase = onStopPhrase
        finalized = ""
        partial = ""
        transcript = ""
        startedAt = Date()
        isRecording = true
        beginCycle()
    }

    /// Stops recording. Returns the transcript (spoken stop phrase removed) and the length in seconds.
    func stop() -> (text: String, seconds: Int) {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        isRecording = false
        cycleTimer?.invalidate()
        cycleTimer = nil
        teardown()
        let text = Self.removeStopPhrase((finalized + " " + partial).trimmingCharacters(in: .whitespacesAndNewlines))
        finalized = ""
        partial = ""
        transcript = ""
        kind = nil
        onStopPhrase = nil
        return (text, seconds)
    }

    // MARK: Cycles

    private func beginCycle() {
        guard isRecording, let recognizer else { return }
        teardown()
        Listener.configureAudioSession()

        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { retrySoon(gen); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tapBlock(request: req))
        engine.prepare()
        do { try engine.start() } catch { retrySoon(gen); return }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in self?.handle(text: text, done: done, generation: gen) }
        }

        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rollOver(gen) }
        }
    }

    private func handle(text: String?, done: Bool, generation gen: Int) {
        guard isRecording, gen == generation else { return }
        if let text, !text.isEmpty {
            partial = text
            transcript = (finalized + " " + partial).trimmingCharacters(in: .whitespacesAndNewlines)
            if let kind, Self.endsWithStopPhrase(transcript, kind: kind) {
                let callback = onStopPhrase
                callback?()
                return
            }
        }
        if done {
            commitPartial()
            retrySoon(gen)
        }
    }

    private func commitPartial() {
        if !partial.isEmpty {
            finalized += (finalized.isEmpty ? "" : " ") + partial
            partial = ""
        }
    }

    /// Ends the current task so its text is finalized, then starts a new one.
    private func rollOver(_ gen: Int) {
        guard isRecording, gen == generation else { return }
        request?.endAudio()
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.isRecording, self.generation == gen else { return }   // the normal path already restarted it
            self.commitPartial()
            self.beginCycle()
        }
    }

    private func retrySoon(_ gen: Int) {
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard self.isRecording, self.generation == gen else { return }
            self.beginCycle()
        }
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: Stop phrases

    private static let meetingStop = #"(?:stop|end|finish)\s+(?:the\s+)?meeting\s+(?:notes|recording|minutes)"#
    private static let journalStop = #"(?:(?:end|stop|finish)\s+(?:my\s+)?journal|i'?m done journaling)"#

    private static func endsWithStopPhrase(_ text: String, kind: Kind) -> Bool {
        let tail = String(text.lowercased().suffix(70))
        let pattern = kind == .meeting ? meetingStop : journalStop
        return tail.range(of: pattern, options: .regularExpression) != nil
    }

    private static func removeStopPhrase(_ text: String) -> String {
        var t = text
        for pattern in [meetingStop, journalStop] {
            t = t.replacingOccurrences(of: pattern + #"[.,!? ]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func tapBlock(request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in request.append(buffer) }
    }
}
