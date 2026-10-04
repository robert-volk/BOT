import AVFoundation

/// BOT's voice: Apple's on-device speech synthesizer. Free, offline, no API.
/// Picks the best installed American-English female voice (Premium > Enhanced > Default) unless you choose one.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    /// Fires once everything queued has been spoken AND `finishInput()` was called.
    var onIdle: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    private var inputDone = true

    var voiceID: String?
    var rate: Float = 0.52
    var pitch: Float = 1.05

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Voice catalog

    struct VoiceInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let quality: String
        let rank: Int
    }

    private static let preferredFemaleNames = ["Ava", "Samantha", "Allison", "Zoe", "Nicky", "Joelle", "Susan", "Noelle"]
    private static let excluded: Set<String> = ["Eddy", "Flo", "Grandma", "Reed", "Rocko", "Sandy", "Shelley", "Kathy", "Princess",
                                                "Junior", "Ralph", "Fred", "Albert", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
                                                "Jester", "Organ", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox"]

    private static func qualityRank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    private static func qualityName(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    /// Female American voices installed on this device, best first.
    static func femaleAmericanVoices() -> [VoiceInfo] {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" && !excluded.contains($0.name) }
        let female = all.filter { $0.gender == .female }
        let pool = female.isEmpty ? all.filter { preferredFemaleNames.contains($0.name) } : female
        return pool
            .sorted { a, b in
                let qa = qualityRank(a), qb = qualityRank(b)
                if qa != qb { return qa > qb }
                let ia = preferredFemaleNames.firstIndex(of: a.name) ?? 99
                let ib = preferredFemaleNames.firstIndex(of: b.name) ?? 99
                return ia < ib
            }
            .map { VoiceInfo(id: $0.identifier, name: $0.name, quality: qualityName($0), rank: qualityRank($0)) }
    }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        if let first = femaleAmericanVoices().first, let v = AVSpeechSynthesisVoice(identifier: first.id) { return v }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let id = voiceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return Self.bestVoice()
    }

    // MARK: Speaking

    /// Queue one chunk (usually a sentence) to be spoken after whatever is already queued.
    func enqueue(_ text: String, language: String? = nil) {
        let clean = SpeechText.clean(text)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = language.flatMap { Translator.voice(for: $0) } ?? resolvedVoice()
        u.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate
        u.pitchMultiplier = pitch
        u.volume = 1.0
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0.02
        pending += 1
        inputDone = false
        isSpeaking = true
        synth.speak(u)
    }

    /// Call when no more chunks will be enqueued for this reply.
    func finishInput() {
        inputDone = true
        checkIdle()
    }

    func stop() {
        inputDone = true
        pending = 0
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func checkIdle() {
        if inputDone && pending <= 0 {
            pending = 0
            isSpeaking = false
            let cb = onIdle
            cb?()
        }
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pending -= 1
            self.checkIdle()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // `stop()` already reset the counters; nothing to do.
    }
}

/// Makes model text safe to read aloud: no markdown symbols, no emoji.
enum SpeechText {
    static func clean(_ s: String) -> String {
        var t = s
        for ch in ["**", "__", "`", "#", "*", "_", ">"] { t = t.replacingOccurrences(of: ch, with: "") }
        t = String(t.unicodeScalars.filter { !($0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x200D) })
        t = t.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Collects streamed text and releases it a sentence at a time so speech can start early.
struct SentenceChunker {
    private var buffer = ""
    private var emittedAny = false
    private static let abbreviations: Set<String> = ["dr", "mr", "mrs", "ms", "st", "vs", "jr", "sr", "etc", "e.g", "i.e"]

    /// Feed new text; returns any complete sentences now ready to speak.
    mutating func feed(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let cut = nextBoundary() {
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !sentence.isEmpty { out.append(sentence); emittedAny = true }
        }
        return out
    }

    /// Whatever is left when the stream ends.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private func nextBoundary() -> String.Index? {
        let chars = Array(buffer)
        guard chars.count > 1 else { return nil }
        var idx = buffer.startIndex
        for i in 0..<chars.count {
            let c = chars[i]
            let next = buffer.index(after: idx)
            defer { idx = next }
            let atEnd = i == chars.count - 1
            if c == "\n" { return next }
            guard ".!?".contains(c) else {
                // Long run with no sentence end: break at a comma so speech doesn't stall.
                if c == ",", i > 70, !atEnd { return next }
                continue
            }
            // A terminator only counts once we've seen what follows (whitespace) so "3.5" isn't split.
            if atEnd { return nil }
            guard chars[i + 1].isWhitespace || chars[i + 1] == "\"" else { continue }
            let word = String(chars[..<i]).split(separator: " ").last.map { $0.lowercased() } ?? ""
            if c == ".", Self.abbreviations.contains(word) || (word.count == 1 && word.first!.isLetter) { continue }
            // Very short first sentence ("Hi.") is fine for speed; otherwise avoid tiny fragments.
            if i < 3 && emittedAny { continue }
            return next
        }
        return nil
    }
}
