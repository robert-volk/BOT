import AVFoundation
import Speech

/// BOT's ears: on-device speech recognition (Speech framework, no network when the device supports it).
/// Ends an utterance automatically after a short silence, or immediately via `finishNow()`.
@MainActor
final class Listener: ObservableObject {
    @Published private(set) var partial = ""
    /// 0...1 microphone level, for the robot's reactions.
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var noSpeechTimer: Timer?
    private var onResult: ((String) -> Void)?
    private var silenceDelay: TimeInterval = 1.0
    private var generation = 0
    private(set) var isListening = false

    // MARK: Permissions

    static func requestPermissions() async -> Bool {
        let speech: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    static func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)
    }

    // MARK: Control

    /// Starts listening. `onResult` is called once with the final text ("" if nothing was heard).
    func start(silenceDelay: TimeInterval, onResult: @escaping (String) -> Void) {
        stopInternal()
        guard let recognizer, recognizer.isAvailable else { onResult(""); return }
        Self.configureAudioSession()

        generation += 1
        let gen = generation
        self.onResult = onResult
        self.silenceDelay = silenceDelay
        partial = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { finish(); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tapBlock(request: req) { [weak self] lvl in
            Task { @MainActor in
                guard let self, abs(lvl - self.level) > 0.04 else { return }
                self.level = lvl
            }
        })

        engine.prepare()
        do { try engine.start() } catch { finish(); return }
        isListening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handle(text: text, isFinal: isFinal, failed: failed, generation: gen)
            }
        }

        // If nothing at all is heard for a while, hand back "" so the conversation can decide what to do.
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: 14, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen, self.partial.isEmpty else { return }
                self.finish()
            }
        }
    }

    /// Sends whatever has been heard so far (tap while listening).
    func finishNow() {
        guard isListening else { return }
        finish()
    }

    func cancel() {
        onResult = nil
        stopInternal()
    }

    // MARK: Internals

    private func handle(text: String?, isFinal: Bool, failed: Bool, generation gen: Int) {
        guard gen == generation, isListening else { return }
        if let text, !text.isEmpty {
            partial = text
            noSpeechTimer?.invalidate()
            silenceTimer?.invalidate()
            silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    self.finish()
                }
            }
        }
        if isFinal || failed { finish() }
    }

    private func finish() {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cb = onResult
        onResult = nil
        stopInternal()
        cb?(text)
    }

    private func stopInternal() {
        silenceTimer?.invalidate(); silenceTimer = nil
        noSpeechTimer?.invalidate(); noSpeechTimer = nil
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        level = 0
    }

    /// Built in a nonisolated context so the closure doesn't inherit main-actor isolation (it runs on the audio thread).
    private nonisolated static func tapBlock(request: SFSpeechAudioBufferRecognitionRequest,
                                             onLevel: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            request.append(buffer)
            onLevel(rms(buffer))
        }
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let r = (sum / Float(n)).squareRoot()
        return min(1, r * 9)
    }
}
