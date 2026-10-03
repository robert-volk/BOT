import SwiftUI
import Combine

enum Phase: Equatable {
    case idle, listening, thinking, speaking
}

/// The loop: listen → think (streaming) → speak sentence-by-sentence → listen again, learning facts as it goes.
@MainActor
final class ConversationEngine: ObservableObject {
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [ChatTurn] = []
    /// The assistant's reply as it streams in (shown as captions).
    @Published private(set) var liveReply = ""
    @Published private(set) var active = false
    @Published private(set) var brainName = ""
    @Published private(set) var brainNote: String?
    @Published private(set) var errorNote: String?
    @Published private(set) var learnedToast: String?
    @Published var permissionDenied = false

    let settings: AppSettings
    let facts: FactStore
    let listener = Listener()
    let speaker = Speaker()

    private var brain: Brain = BasicBrain(note: nil)
    private var replyTask: Task<Void, Never>?
    private var replyID = UUID()
    private var emptyStreak = 0
    private var greeted = false
    private var pendingExtraction: (user: String, assistant: String)?
    private var toastTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    static let claudeKeyAccount = "claude-api-key"

    init(settings: AppSettings, facts: FactStore) {
        self.settings = settings
        self.facts = facts
        listener.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        speaker.onIdle = { [weak self] in self?.speechDidFinish() }
        refreshBrain()
    }

    var partialHeard: String { listener.partial }
    var micLevel: Float { listener.level }
    var prefs: Preferences { settings.prefs }

    // MARK: Brain

    func refreshBrain() {
        let key = Keychain.get(Self.claudeKeyAccount)
        brain = BrainFactory.make(choice: prefs.brain, claudeKey: key)
        brainName = brain.displayName
        brainNote = (brain as? BasicBrain)?.note
    }

    func setClaudeKey(_ key: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.claudeKeyAccount)
        refreshBrain()
    }

    var hasClaudeKey: Bool { !(Keychain.get(Self.claudeKeyAccount) ?? "").isEmpty }

    private func currentSystem() -> String {
        PromptBuilder.system(prefs: prefs, facts: facts.promptBlock(), userName: facts.userName)
    }

    // MARK: User actions

    func primaryTap() {
        Haptics.tap(enabled: prefs.haptics)
        switch phase {
        case .idle:
            Task { await begin() }
        case .listening:
            if listener.partial.isEmpty { end() } else { listener.finishNow() }
        case .thinking, .speaking:
            interrupt()
        }
    }

    /// Stops BOT mid-reply and listens right away.
    private func interrupt() {
        cancelReply()
        speaker.stop()
        flushExtraction()
        startListening()
    }

    func end() {
        active = false
        cancelReply()
        speaker.stop()
        listener.cancel()
        flushExtraction()
        phase = .idle
    }

    func previewVoice() {
        end()
        Listener.configureAudioSession()
        applyVoice()
        speaker.enqueue("Hi, I'm \(prefs.botName). This is how I sound.")
        speaker.finishInput()
    }

    // MARK: Flow

    private func begin() async {
        guard await Listener.requestPermissions() else {
            permissionDenied = true
            return
        }
        errorNote = nil
        active = true
        emptyStreak = 0
        Listener.configureAudioSession()   // playAndRecord, so speech ignores the silent switch
        refreshBrain()
        if !greeted {
            greeted = true
            speakLocal(greeting())
        } else {
            startListening()
        }
    }

    private func greeting() -> String {
        if let name = facts.userName { return "Hey \(name)! Good to hear from you. What's up?" }
        if facts.facts.isEmpty { return "Hi, I'm \(prefs.botName)! I'd love to get to know you. What should I call you?" }
        return "Hey, welcome back. What's on your mind?"
    }

    private func applyVoice() {
        speaker.voiceID = prefs.voiceID
        speaker.rate = Float(prefs.rate)
        speaker.pitch = Float(prefs.pitch)
    }

    private func startListening() {
        guard active else { phase = .idle; return }
        speaker.stop()
        phase = .listening
        brain.prewarm(system: currentSystem())
        listener.start(silenceDelay: prefs.silenceDelay) { [weak self] text in
            self?.heard(text)
        }
    }

    private func heard(_ text: String) {
        guard active else { phase = .idle; return }
        if text.isEmpty {
            emptyStreak += 1
            if emptyStreak >= 2 { end() } else { startListening() }
            return
        }
        emptyStreak = 0
        respond(to: text)
    }

    /// Say something without involving the brain (greetings, memory commands).
    private func speakLocal(_ text: String) {
        applyVoice()
        liveReply = text
        turns.append(ChatTurn(role: .assistant, text: text))
        phase = .speaking
        Haptics.soft(enabled: prefs.haptics)
        speaker.enqueue(text)
        speaker.finishInput()
    }

    private func respond(to text: String) {
        // Memory commands handled locally, instantly.
        if FactExtractor.isForgetEverything(text) {
            turns.append(ChatTurn(role: .user, text: text))
            facts.clear()
            speakLocal("Okay. I've cleared everything I knew about you.")
            return
        }
        if let phrase = FactExtractor.forgetRequest(text) {
            turns.append(ChatTurn(role: .user, text: text))
            let n = facts.forget(matching: phrase)
            speakLocal(n > 0 ? "Okay, I've forgotten that." : "I don't think I had that one, but okay.")
            return
        }
        if let fact = FactExtractor.rememberRequest(text) {
            turns.append(ChatTurn(role: .user, text: text))
            if facts.add(fact, category: .other, pinned: true) { toast(fact) }
            speakLocal("Got it. I'll remember that.")
            return
        }

        let history = turns
        turns.append(ChatTurn(role: .user, text: text))
        if prefs.learnAboutMe {
            for e in FactExtractor.heuristic(text) where facts.add(e.text, category: e.category) { toast(e.text) }
        }

        phase = .thinking
        liveReply = ""
        applyVoice()
        let id = UUID()
        replyID = id
        let system = currentSystem()
        let maxTokens = prefs.replyLength.maxTokens
        let brain = self.brain

        replyTask = Task { [weak self] in
            var chunker = SentenceChunker()
            var full = ""
            var failed = false
            do {
                for try await delta in brain.respond(system: system, history: history, user: text, maxTokens: maxTokens) {
                    guard let self, self.replyID == id, !Task.isCancelled else { return }
                    full += delta
                    self.liveReply = full
                    for s in chunker.feed(delta) { self.say(s) }
                }
            } catch {
                guard let self, self.replyID == id, !Task.isCancelled else { return }
                failed = true
                self.errorNote = error.localizedDescription
            }
            guard let self, self.replyID == id, !Task.isCancelled else { return }

            if let rest = chunker.flush() { self.say(rest) }
            if full.isEmpty || failed && full.count < 3 {
                full = failed ? "Sorry, I'm having trouble thinking right now. Could you try again?"
                              : "Hmm, I lost my train of thought. Could you say that again?"
                self.liveReply = full
                self.say(full)
            }
            self.turns.append(ChatTurn(role: .assistant, text: full))
            self.pendingExtraction = (text, full)
            self.speaker.finishInput()
        }
    }

    private func say(_ sentence: String) {
        if phase != .speaking {
            phase = .speaking
            Haptics.soft(enabled: prefs.haptics)
        }
        speaker.enqueue(sentence)
    }

    private func cancelReply() {
        replyID = UUID()
        replyTask?.cancel()
        replyTask = nil
    }

    private func speechDidFinish() {
        guard phase == .speaking else { return }
        flushExtraction()
        if active && prefs.handsFree {
            startListening()
        } else {
            active = false
            phase = .idle
        }
    }

    // MARK: Learning

    private func flushExtraction() {
        guard let pair = pendingExtraction else { return }
        pendingExtraction = nil
        guard prefs.learnAboutMe, FactExtractor.worthExtracting(pair.user), !(brain is BasicBrain) else { return }
        let brain = self.brain
        let known = facts.promptBlock()
        Task { [weak self] in
            let out = (try? await brain.complete(system: FactExtractor.systemPrompt,
                                                 prompt: FactExtractor.prompt(known: known, user: pair.user, assistant: pair.assistant),
                                                 maxTokens: 120)) ?? ""
            guard let self else { return }
            for e in FactExtractor.parse(out) where self.facts.add(e.text, category: e.category) {
                self.toast(e.text)
            }
        }
    }

    private func toast(_ text: String) {
        learnedToast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { self?.learnedToast = nil }
        }
    }
}

enum Haptics {
    static func tap(enabled: Bool) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func soft(enabled: Bool) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
    }
}
