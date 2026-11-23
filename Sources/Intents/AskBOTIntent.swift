import AppIntents
import Foundation

/// "Hey Siri, ask BOT": a quick question that works with the phone locked. Siri speaks the answer in its own voice.
/// Only safe topics are answered here. BOT's memory, calendar, email, notes and documents are never read.
struct AskBOTIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask BOT"
    static let description = IntentDescription("Ask BOT a quick question without unlocking your iPhone. Private things (email, calendar, notes, documents) need you to unlock and open BOT.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask BOT?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await QuickAsk.answer(question)
        return .result(value: reply, dialog: "\(reply)")
    }
}

/// The locked-phone answer path: reminders, and general questions to the brain with no personal data attached.
@MainActor
enum QuickAsk {
    static let privateReply = "That one is private, so unlock your phone and open BOT."

    private static let privateTopics = #"\b(e-?mails?|inbox|messages?|texts?|calendar|schedule|meetings?|appointments?|agenda|documents?|files?|notes?|journal|lists?|photos?|pictures?|contacts?|passwords?|parked|parking|call|dial|what do you know about me|remember)\b"#

    static func answer(_ raw: String) async -> String {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "I didn't catch a question." }

        let isReminder = ReminderParser.isReminderRequest(q)
        if !isReminder, q.range(of: privateTopics, options: [.regularExpression, .caseInsensitive]) != nil {
            return privateReply
        }
        let prefs = AppSettings().prefs
        if isReminder { return await remind(q, prefs) }
        return await ask(q, prefs)
    }

    private static func remind(_ q: String, _ prefs: Preferences) async -> String {
        let parsed = ReminderParser.parse(q)
        guard let task = parsed.task else { return "I didn't catch what to remind you about." }
        guard let when = parsed.date else { return "I didn't catch when. Try saying: remind me to call Mom at 5." }
        let resolved = ReminderParser.finalizeRepeat(rule: parsed.repeatRule, date: when)
        let center = ReminderCenter.shared
        center.backgroundSpeech = prefs.speakInBackground
        let outcome = await center.schedule(task: task, fire: resolved.date, voiceID: prefs.voiceID,
                                            rate: Float(prefs.rate), pitch: Float(prefs.pitch), repeatRule: resolved.rule)
        switch outcome {
        case .needsPermission:
            return "I need notification permission first. Open BOT and allow notifications."
        case .scheduled:
            let whenText = resolved.rule.map { ReminderParser.repeatPhrase($0, at: resolved.date) } ?? ReminderParser.whenPhrase(resolved.date)
            return task == ReminderParser.timerTask
                ? "Okay, timer set \(whenText)."
                : "Got it. I'll remind you \(whenText): \(ReminderParser.secondPerson(task))."
        }
    }

    private static func ask(_ q: String, _ prefs: Preferences) async -> String {
        let brain = BrainFactory.make(choice: prefs.brain, claudeKey: Keychain.get(ConversationEngine.claudeKeyAccount),
                                      webSearch: prefs.webSearch)
        if brain is BasicBrain { return "I need my Claude key to answer that. Open BOT and add it in Customize." }

        let system = PromptBuilder.system(prefs: prefs, facts: "", userName: nil)
            + " This is a quick answer given through Siri on a locked phone: reply in one or two short sentences, never use [[ ]] tags, and don't ask a follow-up question."
            + " If answering would need their private information (email, calendar, notes, documents, photos), tell them to unlock the phone and open BOT."
        var filter = VisualTagFilter()
        var out = ""
        do {
            for try await delta in brain.respond(system: system, history: [], user: q, maxTokens: 220) {
                out += filter.feed(delta)
            }
            out += filter.flush()
        } catch {
            return "I couldn't reach my brain just now."
        }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Sorry, I don't have an answer for that." : text
    }
}
