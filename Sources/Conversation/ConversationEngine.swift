import SwiftUI
import Combine
import CoreLocation

enum Phase: Equatable {
    case idle, listening, thinking, speaking
}

/// The loop: listen → think (streaming) → speak sentence-by-sentence → listen again, learning facts as it goes.
@MainActor
final class ConversationEngine: ObservableObject {
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [ChatTurn] = [] { didSet { saveHistory() } }
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
    let calendar: CalendarCenter
    let lists: ListStore
    let documents: DocumentStore
    private let phoneActions: PhoneActions
    private let emailAssistant: EmailAssistant
    private let historyURL: URL
    @Published var cameraQuestion: String?
    @Published var cameraReadsText = false
    @Published var previewPhotoIDs: [String] = []
    @Published var visual: Visual?
    private var autoRecording = false
    let recorder = MeetingRecorder()
    private var afterSpeech: (() -> Void)?
    private var lastPlace: String?
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

    init(settings: AppSettings, facts: FactStore, reminders: ReminderCenter, calendar: CalendarCenter, lists: ListStore, email: EmailStore, documents: DocumentStore) {
        self.settings = settings
        self.facts = facts
        self.reminders = reminders
        self.calendar = calendar
        self.lists = lists
        self.documents = documents
        let phone = PhoneActions()
        self.phoneActions = phone
        self.emailAssistant = EmailAssistant(service: EmailService(store: email), phone: phone)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BOT", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.historyURL = support.appendingPathComponent("history.json")
        self.turns = Self.loadHistory(support.appendingPathComponent("history.json"))
        listener.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        speaker.onIdle = { [weak self] in self?.speechDidFinish() }
        reminders.onForegroundFire = { [weak self] line in self?.announce(line) }
        reminders.onBriefing = { [weak self] in self?.startBriefing() }
        reminders.onMeetingNotes = { [weak self] signal in self?.handleMeetingSignal(signal) }
        calendar.factsProvider = { [weak facts] name in
            facts?.facts.filter { $0.text.localizedCaseInsensitiveContains(name) }.map { $0.text } ?? []
        }
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
        // The on-device model sees your schedule freely; Claude only if you opted in (it leaves the phone).
        var cal = ""
        if calendar.authorized && ((brain as? ClaudeBrain) == nil || prefs.calendarToClaude) { cal = calendar.promptBlock() }
        return PromptBuilder.system(prefs: prefs, facts: facts.promptBlock(), userName: facts.userName, calendar: cal)
    }

    // MARK: User actions

    func primaryTap() {
        Haptics.tap(enabled: prefs.haptics)
        if recorder.isRecording { finishRecording(); return }
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

    /// The app was opened or came back to the screen: start listening right away, with no greeting.
    func listenOnOpen() {
        guard prefs.listenOnOpen, !active, phase == .idle, !recorder.isRecording else { return }
        Task { [weak self] in
            // A short pause lets a Siri launch, a notification tap or a reminder claim the microphone first.
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, !self.active, self.phase == .idle, !self.recorder.isRecording else { return }
            guard await Listener.requestPermissions() else { return }   // asks the very first time
            guard !self.active, self.phase == .idle, !self.recorder.isRecording else { return }
            self.errorNote = nil
            self.active = true
            self.emptyStreak = 0
            self.greeted = true
            Listener.configureAudioSession()
            self.refreshBrain()
            self.startListening()
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
    private func speakLocal(_ text: String, isPrivate: Bool = false) {
        applyVoice()
        liveReply = text
        turns.append(ChatTurn(role: .assistant, text: text, isPrivate: isPrivate ? true : nil))
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
        if emailAssistant.wantsToHandle(text) {
            handleEmail(text)
            return
        }
        if ReminderParser.isSnooze(text) {
            turns.append(ChatTurn(role: .user, text: text))
            snooze(text)
            return
        }
        if pendingReminder != nil || ReminderParser.isReminderRequest(text) || ReminderParser.isListRequest(text) || ReminderParser.isCancelAll(text) {
            handleReminder(text)
            return
        }

        if CalendarCenter.isAgendaQuestion(text) {
            handleCalendar(text)
            return
        }
        if handleFeatures(text) { return }

        let history = (brain is ClaudeBrain) ? turns.filter { $0.isPrivate != true } : turns
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
        let metric = prefs.metric
        let brain = self.brain
        let docLookup = lookupDocuments(text)
        let docsToClaude = prefs.docsToClaude
        let answerTokens: Int = {
            if case .context = docLookup { return max(maxTokens, 260) }   // document answers need room to cite
            return maxTokens
        }()

        replyTask = Task { [weak self] in
            var chunker = SentenceChunker()
            var full = ""
            var failed = false
            var system = system
            var direct: String?   // reply that needs no model (Basic mode + live data)

            // Live data the model can't know: look it up first, then let the brain phrase the answer.
            if WeatherService.isWeatherQuestion(text), let svc = self?.weather {
                let result = await svc.report(for: text, metric: metric)
                guard let self, self.replyID == id, !Task.isCancelled else { return }
                switch result {
                case .ok(let spoken, let facts):
                    if brain is BasicBrain { direct = spoken }
                    else { system += "\n\n\(facts)\nAnswer the weather question from this live data, in a sentence or two, without reading every number." }
                case .failed(let message):
                    if brain is BasicBrain { direct = message }
                    else { system += "\n\nThe weather lookup failed: \(message) Tell them that briefly and kindly." }
                }
            } else if case .notADocQuestion = docLookup, let q = self?.searchQuery(for: text, basic: brain is BasicBrain) {
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

            switch docLookup {
            case .notADocQuestion:
                break
            case .direct(let message):
                direct = message
            case .context(let prompt, let extractive):
                if brain is BasicBrain || (brain is ClaudeBrain && !docsToClaude) {
                    direct = extractive
                } else {
                    system += "\n\n" + prompt
                }
            }

            do {
                if let direct {
                    guard let self, self.replyID == id, !Task.isCancelled else { return }
                    full = direct
                    self.liveReply = full
                    for s in chunker.feed(direct + " ") { self.say(s) }
                } else {
                for try await delta in brain.respond(system: system, history: history, user: text, maxTokens: answerTokens) {
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

    // MARK: Features (local intents: handled instantly, any brain)

    private func handleFeatures(_ text: String) -> Bool {
        Conversions.bareDollar = prefs.homeCurrency
        if let life = LifeIntent.parse(text) {
            turns.append(ChatTurn(role: .user, text: text, isPrivate: true))
            handleLife(life)
            return true
        }
        if let intent = VisualIntent.parse(text) {
            turns.append(ChatTurn(role: .user, text: text))
            handleVisual(intent)
            return true
        }
        if let topic = PhotoIntent.parse(text) {
            turns.append(ChatTurn(role: .user, text: text, isPrivate: true))
            let window = DateWindow.parse(text)
            let lower = " " + text.lowercased() + " "
            let personal = window != nil || lower.contains(" my ") || lower.contains("screenshot") || lower.contains("camera roll")
            handlePhotoSearch(topic, window: window, personalOnly: personal)
            return true
        }
        if DocsIntent.isListRequest(text) {
            turns.append(ChatTurn(role: .user, text: text))
            let names = documents.docs.filter { $0.status == "ready" }.map { $0.name }
            speakLocal(names.isEmpty
                ? "You haven't added any documents yet."
                : "You have \(names.count) document\(names.count == 1 ? "" : "s"): " + ListStore.joined(Array(names.prefix(8))) + (names.count > 8 ? ", and more." : "."))
            return true
        }
        if let metric = UnitPreference.parse(text) {
            turns.append(ChatTurn(role: .user, text: text))
            settings.prefs.metric = metric
            speakLocal(metric
                ? "Okay, I'll use metric from now on: kilometers, kilograms and degrees Celsius."
                : "Okay, I'll go back to US units: miles, pounds and degrees Fahrenheit.")
            return true
        }
        if BriefingService.isBriefingRequest(text) {
            turns.append(ChatTurn(role: .user, text: text))
            runBriefing()
            return true
        }
        if let intent = ListIntent.parse(text) {
            turns.append(ChatTurn(role: .user, text: text))
            handleList(intent)
            return true
        }
        if let conversion = Conversions.parse(text) {
            turns.append(ChatTurn(role: .user, text: text))
            phase = .thinking
            Task { [weak self] in
                let answer = await Conversions.convert(conversion)
                self?.speakLocal(answer)
            }
            return true
        }
        if let request = Translator.parse(text) {
            turns.append(ChatTurn(role: .user, text: text))
            translate(request)
            return true
        }
        if let intent = PhoneIntent.parse(text) {
            turns.append(ChatTurn(role: .user, text: text))
            handlePhone(intent)
            return true
        }
        if Self.isHistoryQuestion(text) {
            turns.append(ChatTurn(role: .user, text: text))
            answerHistory(text)
            return true
        }
        if Self.isCameraRequest(text) {
            turns.append(ChatTurn(role: .user, text: text))
            active = false
            cameraReadsText = false
            cameraQuestion = text
            speakLocal("Okay. Point the camera and tap the shutter.")
            return true
        }
        return false
    }

    // MARK: Daily briefing

    /// Used by the menu and the alarm: stop whatever is happening, then brief.
    func requestBriefing() { startBriefing() }

    private func startBriefing() {
        active = false
        cancelReply()
        speaker.stop()
        listener.cancel()
        Listener.configureAudioSession()
        runBriefing()
    }

    private func runBriefing() {
        phase = .thinking
        let name = facts.userName
        let metric = prefs.metric
        let sources: [NewsSource] = NewsSource.allCases.filter { prefs.isEnabled($0) }
        Task { [weak self] in
            guard let self else { return }
            async let news = BriefingService.headlines(from: sources, count: sources.count > 4 ? 1 : (sources.count > 1 ? 2 : 3))
            var parts = [BriefingService.greeting(name: name)]
            if case .ok(let spoken, _) = await self.weather.report(for: "weather today", metric: metric) { parts.append(spoken) }
            if self.calendar.authorized { parts.append(self.calendar.spokenAgenda(for: "today")) }
            let today = self.reminders.items.filter { Calendar.current.isDateInToday($0.fire) }
            if !today.isEmpty {
                parts.append("Reminders today: " + ListStore.joined(today.map { ReminderParser.secondPerson($0.task) }) + ".")
            }
            for group in await news {
                parts.append("From \(group.source): " + group.titles.joined(separator: ". ") + ".")
            }
            self.speakLocal(parts.joined(separator: " "))
        }
    }

    // MARK: Lists & notes

    private func handleList(_ intent: ListIntent) {
        switch intent {
        case .add(let items, let list):
            guard !items.isEmpty else { speakLocal("What should I add?"); return }
            let added = lists.add(items, to: list)
            speakLocal(added.isEmpty ? "That's already on your \(list) list." : "Added \(ListStore.joined(added)) to your \(list) list.")
        case .read(let list):
            speakLocal(lists.spokenList(list))
        case .remove(let item, let list):
            speakLocal(lists.remove(item, from: list) ? "Removed \(item) from your \(list) list." : "I couldn't find \(item) on your \(list) list.")
        case .clear(let list):
            lists.clear(list)
            speakLocal("I've cleared your \(list) list.")
        case .note(let text):
            lists.addNote(text)
            speakLocal("Noted.")
        case .readNotes:
            speakLocal(lists.spokenNotes(lists.data.notes))
        case .searchNotes(let topic):
            speakLocal(lists.spokenNotes(lists.searchNotes(topic)))
        }
    }

    // MARK: Translation

    private func translate(_ r: Translator.Request) {
        phase = .thinking
        let brain = self.brain
        Task { [weak self] in
            guard let self else { return }
            if brain is BasicBrain {
                self.speakLocal("Translation needs the AI brain. Add a Claude key, or turn on Apple Intelligence, in Customize under Brain.")
                return
            }
            let out = (try? await brain.complete(system: Translator.systemPrompt, prompt: Translator.prompt(r), maxTokens: 150)) ?? ""
            let translation = out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"\u{201C}\u{201D}'")))
            guard !translation.isEmpty, translation.uppercased() != "NONE" else {
                self.speakLocal("Sorry, I couldn't translate that.")
                return
            }
            self.speakTranslation(intro: "In \(r.language):", text: translation, code: r.code, language: r.language)
        }
    }

    private func speakTranslation(intro: String, text: String, code: String, language: String) {
        applyVoice()
        let shown = "\(language): \(text)"
        liveReply = shown
        turns.append(ChatTurn(role: .assistant, text: shown))
        phase = .speaking
        speaker.enqueue(intro)
        speaker.enqueue(text, language: code)
        speaker.finishInput()
    }

    // MARK: Call, text, directions, nearby

    private func handlePhone(_ intent: PhoneIntent) {
        phase = .thinking
        Task { [weak self] in
            guard let self else { return }
            switch intent {
            case .directions(let place):
                let destination = (place == "there" || place == "it") ? (self.lastPlace ?? "") : place
                guard !destination.isEmpty else { self.speakLocal("Where would you like to go?"); return }
                self.afterSpeech = { [weak self] in self?.phoneActions.openDirections(to: destination) }
                self.speakLocal("Getting directions to \(destination).")
            case .nearby(let query):
                await self.findNearby(query)
            case .call(let name), .text(let name, _):
                guard await self.phoneActions.requestAccess() else {
                    self.speakLocal(self.phoneActions.isDenied
                        ? "I need access to your contacts. Turn on Contacts for BOT in iPhone Settings, under Privacy and Security."
                        : "Okay, I won't look at your contacts.")
                    return
                }
                guard let match = self.phoneActions.find(name) else {
                    self.speakLocal("I couldn't find \(name) in your contacts.")
                    return
                }
                if case .text(_, let body) = intent {
                    self.afterSpeech = { [weak self] in self?.phoneActions.openText(match.number, body: body) }
                    self.speakLocal(body.isEmpty ? "Opening a message to \(match.name)."
                                                 : "Okay. Here's your message to \(match.name). Tap send when you're ready.")
                } else {
                    self.afterSpeech = { [weak self] in self?.phoneActions.openCall(match.number) }
                    self.speakLocal("Calling \(match.name).")
                }
            }
        }
    }

    private func findNearby(_ query: String) async {
        guard let here = await LocationService.shared.current() else {
            speakLocal("I need location access to find places near you. Turn it on for BOT in iPhone Settings, under Privacy and Security.")
            return
        }
        let places = await LocationService.shared.nearby(query, around: here)
        guard let first = places.first else {
            speakLocal("I couldn't find any \(query) near you.")
            return
        }
        lastPlace = first.name
        let metric = prefs.metric
        func distance(_ p: NearbyPlace) -> String {
            if p.miles < 0.1 { return "right nearby" }
            return metric ? String(format: "%.1f kilometers away", p.miles * 1.609344) : String(format: "%.1f miles away", p.miles)
        }
        var reply = "The closest is \(first.name), \(distance(first))."
        if places.count > 1 {
            reply += " Next are " + ListStore.joined(places.dropFirst().map { "\($0.name), \(distance($0))" }) + "."
        }
        reply += " Say directions there, and I'll open Maps."
        speakLocal(reply)
    }

    // MARK: Conversation history

    private static func loadHistory(_ url: URL) -> [ChatTurn] {
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([ChatTurn].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        return decoded.filter { $0.date > cutoff }
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(Array(turns.suffix(400))) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private static func isHistoryQuestion(_ t: String) -> Bool {
        t.range(of: #"\bwhat (?:did|were) we (?:talk|chat|discuss|talking|chatting|discussing)\b|\bwhat have we (?:talked|chatted|discussed)\b|\bremind me what we (?:talked|discussed)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func answerHistory(_ text: String) {
        let lower = text.lowercased()
        let cal = Calendar.current
        let previous = Array(turns.dropLast()).filter { !(brain is ClaudeBrain) || $0.isPrivate != true }   // before this question; no email for Claude
        let day: Date? = lower.contains("yesterday") ? cal.date(byAdding: .day, value: -1, to: Date())
            : (lower.contains("today") ? Date() : nil)
        let relevant = previous.filter { t in day.map { cal.isDate(t.date, inSameDayAs: $0) } ?? true }
        let userLines = relevant.filter { $0.role == .user }
        guard !userLines.isEmpty else {
            speakLocal(day == nil ? "We haven't talked about anything yet." : "We didn't talk then.")
            return
        }
        if brain is BasicBrain {
            speakLocal("You asked about: " + ListStore.joined(userLines.suffix(4).map { String($0.text.prefix(60)) }) + ".")
            return
        }
        phase = .thinking
        var transcript = ""
        for t in relevant.suffix(30) {
            transcript += (t.role == .user ? "Them: " : "You: ") + String(t.text.prefix(160)) + "\n"
        }
        let system = "You summarize past conversations aloud in two or three casual spoken sentences. No lists, no markdown."
        let prompt = "Question: \"\(text)\"\n\nConversation:\n\(transcript)\nSummarize what we talked about, speaking to them as 'you'."
        let b = brain
        Task { [weak self] in
            let out = (try? await b.complete(system: system, prompt: prompt, maxTokens: 160)) ?? ""
            let answer = out.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.speakLocal(answer.isEmpty || answer.uppercased() == "NONE" ? "I couldn't pull that up." : answer)
        }
    }

    // MARK: Camera

    private static func isCameraRequest(_ t: String) -> Bool {
        t.range(of: #"\b(?:what is this|what'?s this|what am i looking at|look at this|identify this|use the camera|take a (?:picture|photo)|is this safe)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    func requestCamera(_ question: String, readText: Bool = false) {
        end()
        cameraReadsText = readText
        cameraQuestion = question
    }

    /// The shutter was tapped: either read the text aloud (on-device) or describe the photo (Claude).
    func photoCaptured(_ data: Data) {
        let question = cameraQuestion ?? "What is this?"
        let readsText = cameraReadsText
        cameraQuestion = nil
        cameraReadsText = false
        if readsText { readText(from: data) } else { describePhoto(data, question: question) }
    }

    private func readText(from data: Data) {
        phase = .thinking
        Task { [weak self] in
            let text = await TextReader.read(data)
            guard let self else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.speakLocal(clean.isEmpty ? "I couldn't find any text in that photo." : String(clean.prefix(2500)), isPrivate: true)
        }
    }

    func describePhoto(_ jpegData: Data, question: String) {
        guard let claude = brain as? ClaudeBrain else {
            speakLocal("Looking at photos needs a Claude key. Add one in Customize, under Brain.")
            return
        }
        phase = .thinking
        let image = Self.resized(jpegData)
        let system = "You are \(prefs.botName), a voice assistant looking through the user's phone camera. Answer what they asked about the photo in two or three short spoken sentences. No markdown, no lists."
        Task { [weak self] in
            do {
                let text = try await claude.vision(system: system, jpeg: image, question: question, maxTokens: 220)
                self?.speakLocal(text.isEmpty ? "I couldn't make that out." : text)
            } catch {
                self?.errorNote = error.localizedDescription
                self?.speakLocal("Sorry, I couldn't look at that one.")
            }
        }
    }

    private static func resized(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1024 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let out = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return out.jpegData(compressionQuality: 0.7) ?? data
    }

    // MARK: Photos

    /// "Find photos of the receipt from March": matched on-device by the text and contents BOT read from your photos.
    private func handlePhotoSearch(_ topic: String, window: ClosedRange<Date>?, personalOnly: Bool) {
        let braveKey = Keychain.get(Self.braveKeyAccount)
        // Nothing of yours matches: fall back to pictures from the web (unless the question was clearly about your own photos).
        func fallback(_ intro: String) {
            if personalOnly || DocumentStore.terms(topic).isEmpty {
                speakLocal(intro.isEmpty ? "I couldn't find a matching photo." : intro, isPrivate: true)
            } else {
                phase = .thinking
                Task { [weak self] in await self?.showWebImages(topic, intro: intro, braveKey: braveKey) }
            }
        }
        guard documents.hasPhotoChunks else {
            if personalOnly {
                speakLocal("You haven't added any photo albums yet. Open Documents from the menu, then add photo albums.", isPrivate: true)
            } else {
                fallback("")
            }
            return
        }
        let chunks: [DocChunk]
        if DocumentStore.terms(topic).isEmpty {
            chunks = documents.recentPhotoChunks(in: window, limit: 8)
        } else {
            chunks = documents.search(topic, limit: 12, scope: .photos, dateWindow: window).filter { $0.score >= 0.25 }.map { $0.chunk }
        }
        var ids: [String] = []
        var seen = Set<String>()
        for c in chunks { if let id = c.assetID, seen.insert(id).inserted { ids.append(id) } }
        guard let best = chunks.first, !ids.isEmpty else {
            fallback(personalOnly ? "" : "I couldn't find that in your photos. ")
            return
        }
        previewPhotoIDs = Array(ids.prefix(8))
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        var reply = "I found \(ids.count) photo\(ids.count == 1 ? "" : "s") of yours. The best match is from "
            + (best.date.map { formatter.string(from: $0) } ?? "an unknown date") + "."
        if let r = best.text.range(of: "Text in photo: ") { reply += " Its text says: " + String(best.text[r.upperBound...].prefix(220)) }
        speakLocal(reply, isPrivate: true)
    }

    // MARK: Pictures, maps, charts and diagrams

    private func handleVisual(_ intent: VisualIntent) {
        phase = .thinking
        let metric = prefs.metric
        let braveKey = Keychain.get(Self.braveKeyAccount)
        let brain = self.brain
        Task { [weak self] in
            guard let self else { return }
            switch intent {
            case .images(let query):
                await self.showWebImages(query, intro: "", braveKey: braveKey)

            case .map(let place):
                var coordinate: CLLocationCoordinate2D?
                var title = place
                let lower = place.lowercased()
                if place.isEmpty || lower == "here" || lower == "me" || lower == "my location" {
                    let here = await LocationService.shared.current()
                    coordinate = here?.coordinate
                    title = "your location"
                } else {
                    coordinate = await LocationService.shared.geocode(place)
                }
                guard let c = coordinate else {
                    self.speakLocal("I couldn't find \(place.isEmpty ? "your location" : place) on the map.")
                    return
                }
                self.visual = .map(title: title.capitalizedFirst, coordinate: c)
                self.speakLocal("Here's the map of \(title).")

            case .weatherChart(let place):
                var coordinate: CLLocationCoordinate2D?
                var label = "your area"
                if place.isEmpty {
                    let here = await LocationService.shared.current()
                    coordinate = here?.coordinate
                } else {
                    coordinate = await LocationService.shared.geocode(place)
                    label = place
                }
                guard let c = coordinate else {
                    self.speakLocal("I need a location for the forecast. Turn on location access, or say a city.")
                    return
                }
                let days = await self.weather.forecastSeries(lat: c.latitude, lon: c.longitude, metric: metric)
                guard !days.isEmpty else {
                    self.speakLocal("I couldn't get the forecast right now.")
                    return
                }
                self.visual = .forecast(place: label.capitalizedFirst, days: days, metric: metric)
                self.speakLocal("Here's the seven day forecast for \(label).")

            case .diagram(let subject):
                guard !(brain is BasicBrain) else {
                    self.speakLocal("Drawing needs the AI brain. Add a Claude key in Customize, under Brain.")
                    return
                }
                self.speakLocal("Okay, drawing that now.")
                let system = "You draw clear diagrams and illustrations as SVG. Output ONLY one complete <svg> element: viewBox=\"0 0 800 600\", self-contained, no scripts, no external images or links, large readable text labels (font-size at least 18), simple shapes, arrows where useful, good color contrast, white background. No explanation, no markdown."
                let out = (try? await brain.complete(system: system, prompt: "Draw: \(subject)", maxTokens: 3500)) ?? ""
                guard let svg = SVGSanitizer.extract(out) else {
                    self.speakLocal("Sorry, I couldn't draw that one. Try describing it a little differently.")
                    return
                }
                self.visual = .diagram(title: subject.capitalizedFirst, svg: svg)
                self.speakLocal("Here's your diagram.")
            }
        }
    }

    private func showWebImages(_ query: String, intro: String, braveKey: String?) async {
        let images = await ImageSearchService.search(query, braveKey: braveKey, limit: 8)
        guard !images.isEmpty else {
            speakLocal(intro + "I couldn't find pictures of \(query).")
            return
        }
        visual = .images(query: query, images: images)
        speakLocal(intro + "Here are \(images.count) pictures of \(query), from the web. Swipe to see more.")
    }

    // MARK: Documents

    private enum DocLookup {
        case notADocQuestion
        case direct(String)
        case context(prompt: String, extractive: String)
    }

    /// Finds the passages of your own documents that answer this question (or says there are none).
    private func lookupDocuments(_ text: String) -> DocLookup {
        let explicit = DocsIntent.isExplicit(text)
        guard explicit || (prefs.docsAlways && !documents.isEmpty) else { return .notADocQuestion }
        guard !documents.isEmpty else {
            return explicit
                ? .direct("You haven't added any documents yet. Open Documents from the menu at the top to add some.")
                : .notADocQuestion
        }
        let hits = documents.search(DocsIntent.query(from: text), limit: 5).filter { $0.score >= (explicit ? 0.3 : 0.55) }
        guard !hits.isEmpty else {
            return explicit ? .direct("I couldn't find that in your documents.") : .notADocQuestion
        }

        let budget = brain is ClaudeBrain ? 7000 : 3000
        var excerpts = ""
        for (i, h) in hits.enumerated() {
            let place = h.chunk.location.isEmpty ? "" : ", " + h.chunk.location
            let block = "[\(i + 1)] \(h.chunk.docName)\(place)\n\(h.chunk.text)\n\n"
            if excerpts.count + block.count > budget, i > 0 { break }
            excerpts += block
        }
        let prompt = """
        DOCUMENT EXCERPTS from the user's own library. Answer their question using ONLY these excerpts. If the excerpts do not contain the answer, say you couldn't find it in their documents; never guess or use outside knowledge for this question. Mention which document (and page or sheet) you used, briefly and naturally, for example "According to the Travel Policy, page 3, ...". Give names, numbers and dates exactly as written.

        \(excerpts)
        """
        let top = hits[0].chunk
        let place = top.location.isEmpty ? "" : ", " + top.location
        let extractive = "From \(top.docName)\(place): " + String(top.text.prefix(450))
        return .context(prompt: prompt, extractive: extractive)
    }

    // MARK: Email

    private func handleEmail(_ text: String) {
        turns.append(ChatTurn(role: .user, text: text, isPrivate: true))
        phase = .thinking
        let name = facts.userName
        let onDevice = BrainFactory.onDeviceBrain()
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.emailAssistant.respond(to: text, userName: name, onDevice: onDevice)
            if let url = self.emailAssistant.takeMailURL() {
                self.afterSpeech = { UIApplication.shared.open(url) }
            }
            self.speakLocal(reply, isPrivate: true)
        }
    }

    // MARK: Meeting notes, journal, parking

    private func handleLife(_ intent: LifeIntent) {
        switch intent {
        case .startMeeting:
            startRecording(.meeting)
        case .startJournal:
            startRecording(.journal)
        case .journalNow(let text):
            lists.addJournal(text.capitalizedFirst, mood: nil)
            speakLocal("Saved to your journal.", isPrivate: true)
        case .reflectWeek:
            reflectOnWeek()
        case .lastMeeting:
            guard let m = lists.meetings.last else {
                speakLocal("I don't have any meeting notes yet.", isPrivate: true)
                return
            }
            let day = DateFormatter()
            day.dateFormat = "EEEE"
            var reply = "Your last meeting, on \(day.string(from: m.date)), ran \(m.minutes) minutes. \(m.summary)"
            if !m.actions.isEmpty { reply += " Action items: " + ListStore.joined(m.actions) + "." }
            speakLocal(reply, isPrivate: true)
        case .parkHere(let note):
            saveParking(note: note)
        case .whereParked:
            findParking()
        case .readText:
            active = false
            cameraReadsText = true
            cameraQuestion = "Point at the text and tap the shutter."
            speakLocal("Okay. Point the camera at the text and tap the shutter.", isPrivate: true)
        }
    }

    /// Starts listening to a meeting or journal entry. Everything stays on this phone.
    func startRecording(_ kind: MeetingRecorder.Kind) {
        Task { [weak self] in
            guard let self else { return }
            guard await Listener.requestPermissions() else {
                self.permissionDenied = true
                return
            }
            self.end()
            let intro = kind == .meeting
                ? "Okay, I'm taking meeting notes. Say stop meeting notes when you're done, or tap Stop."
                : "I'm listening. Say end journal when you're done, or tap Stop."
            self.afterSpeech = { [weak self] in
                self?.recorder.start(kind: kind) { [weak self] in self?.finishRecording() }
            }
            self.speakLocal(intro, isPrivate: true)
        }
    }

    func finishRecording(speak: Bool = true) {
        guard recorder.isRecording, let kind = recorder.kind else { return }
        let speak = speak && !autoRecording      // notes that started automatically never talk
        let title = recorder.title
        let result = recorder.stop()
        recorder.title = nil
        autoRecording = false
        if speak { phase = .thinking }
        let onDevice = BrainFactory.onDeviceBrain()
        Task { [weak self] in
            guard let self else { return }
            guard !result.text.isEmpty else {
                if speak { self.speakLocal("I didn't catch anything, so I didn't save it.", isPrivate: true) }
                return
            }
            switch kind {
            case .meeting:
                let summary = await MeetingSummarizer.summarize(result.text, brain: onDevice)
                let minutes = max(1, (result.seconds + 30) / 60)
                self.lists.addMeeting(MeetingNote(minutes: minutes, summary: summary.summary, actions: summary.actions,
                                                  transcript: result.text, title: title))
                if !summary.actions.isEmpty { self.lists.add(summary.actions, to: "to-do") }
                let n = summary.actions.count
                if speak {
                    var reply = "Saved your meeting notes" + (title.map { " for \($0)" } ?? "")
                        + ", \(minutes) minute\(minutes == 1 ? "" : "s"). Summary: \(summary.summary)"
                    if n > 0 {
                        reply += " I found \(n) action item\(n == 1 ? "" : "s") and added \(n == 1 ? "it" : "them") to your to-do list: "
                            + ListStore.joined(Array(summary.actions.prefix(3))) + "."
                    }
                    self.speakLocal(reply, isPrivate: true)
                } else {
                    // Automatic notes never talk during a meeting: a quiet notification instead.
                    self.reminders.postNow(title: "Meeting notes saved" + (title.map { ": \($0)" } ?? ""),
                                           body: String(summary.summary.prefix(160))
                                               + (n > 0 ? " \(n) action item\(n == 1 ? "" : "s") added to your to-do list." : ""))
                }
            case .journal:
                var mood: String?
                if let brain = onDevice,
                   let out = try? await brain.complete(system: "In two or three words, describe the writer's mood. No punctuation, no sentence.",
                                                       prompt: String(result.text.prefix(1500)), maxTokens: 12) {
                    let m = out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".\""))).lowercased()
                    if !m.isEmpty && m != "none" { mood = m }
                }
                self.lists.addJournal(result.text, mood: mood)
                self.speakLocal("Saved your journal entry." + (mood.map { " You sound \($0)." } ?? ""), isPrivate: true)
            }
        }
    }

    /// A calendar meeting started or ended (automatic meeting notes).
    private func handleMeetingSignal(_ signal: MeetingSignal) {
        switch signal {
        case .start(let title):
            guard !recorder.isRecording else { return }
            Task { [weak self] in
                guard let self else { return }
                guard await Listener.requestPermissions() else { return }
                self.end()
                Listener.configureAudioSession()
                self.recorder.title = title
                self.recorder.onFailure = { [weak self] in
                    self?.autoRecording = false
                    self?.reminders.postNow(title: "Couldn't start meeting notes", body: "Tap to start notes: \(title)",
                                            userInfo: ["notesStart": title,
                                                       "notesEnd": Date().addingTimeInterval(3 * 3600).timeIntervalSince1970])
                }
                self.recorder.start(kind: .meeting) { [weak self] in self?.finishRecording() }
                self.autoRecording = self.recorder.isRecording
                Haptics.tap(enabled: self.prefs.haptics)
            }
        case .stop:
            guard recorder.isRecording, autoRecording else { return }
            finishRecording(speak: false)
        }
    }

    private func reflectOnWeek() {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let entries = lists.journal.filter { $0.date > cutoff }
        guard let latest = entries.last else {
            speakLocal("You haven't written any journal entries this week.", isPrivate: true)
            return
        }
        guard let brain = BrainFactory.onDeviceBrain() else {
            speakLocal("You wrote \(entries.count) journal entr\(entries.count == 1 ? "y" : "ies") this week. The latest begins: "
                       + String(latest.text.prefix(120)), isPrivate: true)
            return
        }
        phase = .thinking
        let day = DateFormatter()
        day.dateFormat = "EEEE"
        var text = ""
        for e in entries { text += "\(day.string(from: e.date)): \(String(e.text.prefix(500)))\n" }
        let prompt = String(text.prefix(3000))
        Task { [weak self] in
            let system = "You are a kind, thoughtful friend. In three or four spoken sentences, reflect on the user's journal entries from the past week: themes, mood, and anything to look forward to. Speak to them as 'you'. No lists, no markdown."
            let out = (try? await brain.complete(system: system, prompt: prompt, maxTokens: 220)) ?? ""
            let answer = out.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.speakLocal(answer.isEmpty ? "I couldn't put that together." : answer, isPrivate: true)
        }
    }

    private func saveParking(note: String) {
        phase = .thinking
        Task { [weak self] in
            guard let self else { return }
            guard let here = await LocationService.shared.current() else {
                self.speakLocal("I need location access to remember where you parked. Turn it on for BOT in iPhone Settings, under Privacy and Security.")
                return
            }
            let place = await LocationService.shared.describe(here)
            self.lists.setParking(ParkingSpot(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude,
                                              place: place, note: note, date: Date()))
            self.speakLocal("Okay, I saved your parking spot near \(place)" + (note.isEmpty ? "." : ", \(note)."))
        }
    }

    private func findParking() {
        guard let spot = lists.data.parking else {
            speakLocal("I don't have a parking spot saved. Say remember where I parked when you park.")
            return
        }
        phase = .thinking
        let metric = prefs.metric
        Task { [weak self] in
            guard let self else { return }
            let ago = RelativeDateTimeFormatter().localizedString(for: spot.date, relativeTo: Date())
            var reply = "You parked near \(spot.place)" + (spot.note.isEmpty ? "" : ", \(spot.note)") + ", \(ago)."
            if let here = await LocationService.shared.current() {
                let meters = here.distance(from: CLLocation(latitude: spot.latitude, longitude: spot.longitude))
                reply += " It's about " + Self.distanceText(meters, metric: metric) + " away."
            }
            reply += " Opening walking directions."
            self.afterSpeech = {
                if let url = URL(string: "https://maps.apple.com/?daddr=\(spot.latitude),\(spot.longitude)&dirflg=w") {
                    UIApplication.shared.open(url)
                }
            }
            self.speakLocal(reply)
        }
    }

    private static func distanceText(_ meters: Double, metric: Bool) -> String {
        if metric {
            return meters < 950 ? "\(Int((meters / 10).rounded()) * 10) meters" : String(format: "%.1f kilometers", meters / 1000)
        }
        let feet = meters * 3.28084
        return feet < 1000 ? "\(Int((feet / 10).rounded()) * 10) feet" : String(format: "%.1f miles", meters / 1609.344)
    }

    // MARK: Claude key test

    /// Shows what's saved (start and last 4 characters only) and asks Anthropic whether it accepts the key.
    func testClaudeKey() async -> [String] {
        guard let key = Keychain.get(Self.claudeKeyAccount), !key.isEmpty else {
            return ["FAIL: no Claude key is saved. Paste one in the box above and tap Save key."]
        }
        var lines = ["Saved key: \(key.prefix(12))...\(key.suffix(4)) (\(key.count) characters)"]
        if !key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 }) {
            lines.append("FAIL: the key contains spaces or unusual characters. Remove it, copy it again from the Console, and paste.")
        }
        if !key.hasPrefix("sk-ant-api") {
            lines.append("FAIL: this doesn't look like an API key. It should start with sk-ant-api03. A key starting sk-ant-oat is a Claude Code login token and will not work here; create an API key at console.anthropic.com instead.")
        }
        do {
            _ = try await ClaudeBrain(apiKey: key).complete(system: "Reply with the single word OK.", prompt: "ping", maxTokens: 8)
            lines.append("OK: Anthropic accepted the key.")
        } catch {
            lines.append("FAIL: Anthropic replied: \(error.localizedDescription)")
        }
        return lines
    }

    // MARK: Calendar

    private func handleCalendar(_ text: String) {
        turns.append(ChatTurn(role: .user, text: text))
        phase = .thinking
        Task { [weak self] in
            guard let self else { return }
            if !self.calendar.authorized {
                if self.calendar.isDenied {
                    self.speakLocal("I don't have permission to see your calendar. Turn on Calendars for BOT in iPhone Settings, under Privacy and Security.")
                    return
                }
                guard await self.calendar.requestAccess() else {
                    self.speakLocal("Okay, I won't look at your calendar.")
                    return
                }
                await self.calendar.sync(with: self.settings.prefs)
            }
            self.speakLocal(self.calendar.spokenAgenda(for: text))
        }
    }

    // MARK: Reminders

    private struct PendingReminder {
        var task: String?
        var date: Date?
        var rule: String?
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
        var rule: String?
        if let p = pendingReminder, !ReminderParser.isReminderRequest(text) {
            // They're answering "when?" or "what about?"
            task = p.task
            date = p.date
            rule = p.rule
            if date == nil {
                let parsed = ReminderParser.parse(text)
                date = parsed.date
                if task == nil { task = parsed.task }
                if rule == nil { rule = parsed.repeatRule }
            } else if task == nil {
                task = text
            }
        } else {
            let parsed = ReminderParser.parse(text)
            task = parsed.task
            date = parsed.date
            rule = parsed.repeatRule
        }
        pendingReminder = nil

        guard let when = date else {
            pendingReminder = PendingReminder(task: task, date: nil, rule: rule)
            speakLocal(task == nil ? "Sure. What should I remind you about, and when?" : "When should I remind you?")
            return
        }
        guard let what = task else {
            pendingReminder = PendingReminder(task: nil, date: when, rule: rule)
            speakLocal("What should I remind you about?")
            return
        }
        let resolved = ReminderParser.finalizeRepeat(rule: rule, date: when)
        scheduleReminder(task: what, when: resolved.date, rule: resolved.rule, announcement: nil)
    }

    private func scheduleReminder(task what: String, when: Date, rule: String?, announcement: String?) {
        phase = .thinking
        let voice = prefs.voiceID, rate = Float(prefs.rate), pitch = Float(prefs.pitch)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.reminders.schedule(task: what, fire: when, voiceID: voice, rate: rate, pitch: pitch, repeatRule: rule)
            switch outcome {
            case .needsPermission:
                self.speakLocal("I need notification permission to remind you. Turn on notifications for BOT in the iPhone Settings app, then ask me again.")
            case .scheduled(let spokenBanner):
                let whenText = rule.map { ReminderParser.repeatPhrase($0, at: when) } ?? ReminderParser.whenPhrase(when)
                var reply = announcement ?? (what == ReminderParser.timerTask
                    ? "Okay, timer set \(whenText)."
                    : "Got it. I'll remind you \(whenText): \(ReminderParser.secondPerson(what)).")
                if !spokenBanner { reply += " I couldn't prepare a spoken alert, so when the app is closed you'll get the banner and a chime." }
                self.speakLocal(reply)
            }
        }
    }

    private func snooze(_ text: String) {
        guard let task = reminders.lastFiredTask else {
            speakLocal("I don't have a reminder to snooze.")
            return
        }
        let minutes = ReminderParser.snoozeMinutes(text)
        scheduleReminder(task: task, when: Date().addingTimeInterval(Double(minutes) * 60), rule: nil,
                         announcement: "Okay, snoozed for \(minutes) minute\(minutes == 1 ? "" : "s").")
    }

    /// A reminder fired while the app was open: say it out loud right now.
    private func announce(_ line: String) {
        active = false
        cancelReply()
        speaker.stop()
        listener.cancel()
        Listener.configureAudioSession()
        speakLocal(line)
        if line.hasPrefix("Reminder") || line.hasPrefix("Your timer") {
            active = true        // listen once afterwards, so you can say "snooze"
            emptyStreak = 1
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
        if let action = afterSpeech {
            afterSpeech = nil
            active = false
            phase = .idle
            action()
            return
        }
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
