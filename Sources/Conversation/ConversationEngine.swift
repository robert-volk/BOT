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
    let reminders: ReminderCenter
    let listener = Listener()
    let speaker = Speaker()
    private let weather = WeatherService()

    private var brain: Brain = BasicBrain(note: nil)
    private var replyTask: Task<Void, Never>?
    private var replyID = UUID()
    private var emptyStreak = 0
    private var greeted = false
    private var pendingExtraction: (user: String, assistant: String)?
    private var toastTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    static let claudeKeyAccount = "claude-api-key"
    static let braveKeyAccount = "brave-api-key"

    init(settings: AppSettings, facts: FactStore, reminders: ReminderCenter) {
        self.settings = settings
        self.facts = facts
        self.reminders = reminders
        listener.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        speaker.onIdle = { [weak self] in self?.speechDidFinish() }
        reminders.onForegroundFire = { [weak self] line in self?.announce(line) }
        refreshBrain()
    }

    var partialHeard: String { listener.partial }
    var micLevel: Float { listener.level }
    var prefs: Preferences { settings.prefs }

    // MARK: Brain

    func refreshBrain() {
        let key = Keychain.get(Self.claudeKeyAccount)
        brain = BrainFactory.make(choice: prefs.brain, claudeKey: key, webSearch: prefs.webSearch)
        brainName = brain.displayName
        brainNote = (brain as? BasicBrain)?.note
    }

    func setClaudeKey(_ key: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.claudeKeyAccount)
        refreshBrain()
    }

    func setBraveKey(_ key: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.braveKeyAccount)
        objectWillChange.send()
    }

    var hasBraveKey: Bool { !(Keychain.get(Self.braveKeyAccount) ?? "").isEmpty }

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

    private func begin(fromSiri: Bool = false) async {
        guard await Listener.requestPermissions() else {
            permissionDenied = true
            return
        }
        errorNote = nil
        active = true
        emptyStreak = 0
        Listener.configureAudioSession()   // playAndRecord, so speech ignores the silent switch
        refreshBrain()
        if fromSiri {
            greeted = true
            speakLocal(["Yes?", "I'm listening.", "Hi there!", "Yeah?"].randomElement() ?? "Yes?")
        } else if !greeted {
            greeted = true
            speakLocal(greeting())
        } else {
            startListening()
        }
    }

    /// "Hey Siri, talk to BOT" (or a Shortcut / the Action Button) landed in the app.
    func startFromSiri() {
        guard !active else { return }
        Task { await begin(fromSiri: true) }
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

        if text.range(of: #"^(?:ok(?:ay)?,? |hey,? )?(?:good ?bye|bye(?: bye)?|that'?s all|that is all|stop listening|go to sleep|talk to you later)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            turns.append(ChatTurn(role: .user, text: text))
            active = false                 // so the conversation ends after this line
            speakLocal("Okay, talk to you later!")
            return
        }
        if pendingReminder != nil || ReminderParser.isReminderRequest(text) || ReminderParser.isListRequest(text) || ReminderParser.isCancelAll(text) {
            handleReminder(text)
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
            var system = system
            var direct: String?   // reply that needs no model (Basic mode + live data)

            // Live data the model can't know: look it up first, then let the brain phrase the answer.
            if WeatherService.isWeatherQuestion(text), let svc = self?.weather {
                let result = await svc.report(for: text)
                guard let self, self.replyID == id, !Task.isCancelled else { return }
                switch result {
                case .ok(let spoken, let facts):
                    if brain is BasicBrain { direct = spoken }
                    else { system += "\n\n\(facts)\nAnswer the weather question from this live data, in a sentence or two, without reading every number." }
                case .failed(let message):
                    if brain is BasicBrain { direct = message }
                    else { system += "\n\nThe weather lookup failed: \(message) Tell them that briefly and kindly." }
                }
            } else if let q = self?.searchQuery(for: text, basic: brain is BasicBrain) {
                let result = await WebSearchService(braveKey: Keychain.get(Self.braveKeyAccount)).search(q)
                guard let self, self.replyID == id, !Task.isCancelled else { return }
                switch result {
                case .ok(let spoken, let facts):
                    if brain is BasicBrain { direct = spoken }
                    else { system += "\n\n\(facts)" }
                case .failed(let message):
                    if brain is BasicBrain { direct = message }
                    else { system += "\n\nA web search just failed: \(message) Tell them that briefly and kindly." }
                }
            }

            do {
                if let direct {
                    guard let self, self.replyID == id, !Task.isCancelled else { return }
                    full = direct
                    self.liveReply = full
                    for s in chunker.feed(direct + " ") { self.say(s) }
                } else {
                for try await delta in brain.respond(system: system, history: history, user: text, maxTokens: maxTokens) {
                    guard let self, self.replyID == id, !Task.isCancelled else { return }
                    full += delta
                    self.liveReply = full
                    for s in chunker.feed(delta) { self.say(s) }
                }
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

    private func searchQuery(for text: String, basic: Bool) -> String? {
        // Claude searches natively (and better) when it has the tool; our own pipeline covers everything else.
        guard prefs.webSearch, (brain as? ClaudeBrain)?.nativeSearch != true else { return nil }
        return WebSearchService.query(for: text, basic: basic)
    }

    // MARK: Reminders

    private struct PendingReminder {
        var task: String?
        var date: Date?
    }
    private var pendingReminder: PendingReminder?

    private func handleReminder(_ text: String) {
        turns.append(ChatTurn(role: .user, text: text))

        if ReminderParser.isCancelAll(text) {
            pendingReminder = nil
            reminders.cancelAll()
            speakLocal("Okay, I've cleared your reminders.")
            return
        }
        if ReminderParser.isListRequest(text) {
            speakLocal(reminders.spokenList())
            return
        }
        if pendingReminder != nil && ReminderParser.isNevermind(text) {
            pendingReminder = nil
            speakLocal("Okay, no reminder.")
            return
        }

        var task: String?
        var date: Date?
        if let p = pendingReminder, !ReminderParser.isReminderRequest(text) {
            // They're answering "when?" or "what about?"
            task = p.task
            date = p.date
            if date == nil {
                let parsed = ReminderParser.parse(text)
                date = parsed.date
                if task == nil { task = parsed.task }
            } else if task == nil {
                task = text
            }
        } else {
            let parsed = ReminderParser.parse(text)
            task = parsed.task
            date = parsed.date
        }
        pendingReminder = nil

        guard let when = date else {
            pendingReminder = PendingReminder(task: task, date: nil)
            speakLocal(task == nil ? "Sure. What should I remind you about, and when?" : "When should I remind you?")
            return
        }
        guard let what = task else {
            pendingReminder = PendingReminder(task: nil, date: when)
            speakLocal("What should I remind you about?")
            return
        }

        phase = .thinking
        let voice = prefs.voiceID, rate = Float(prefs.rate), pitch = Float(prefs.pitch)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.reminders.schedule(task: what, fire: when, voiceID: voice, rate: rate, pitch: pitch)
            switch outcome {
            case .needsPermission:
                self.speakLocal("I need notification permission to remind you. Turn on notifications for BOT in the iPhone Settings app, then ask me again.")
            case .scheduled(let spokenBanner):
                let whenText = ReminderParser.whenPhrase(when)
                var reply = what == ReminderParser.timerTask
                    ? "Okay, timer set \(whenText)."
                    : "Got it. I'll remind you \(whenText): \(ReminderParser.secondPerson(what))."
                if !spokenBanner { reply += " I couldn't prepare a spoken alert, so when the app is closed you'll get the banner and a chime." }
                self.speakLocal(reply)
            }
        }
    }

    /// A reminder fired while the app was open: say it out loud right now.
    private func announce(_ line: String) {
        active = false
        cancelReply()
        speaker.stop()
        listener.cancel()
        Listener.configureAudioSession()
        speakLocal(line)
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
