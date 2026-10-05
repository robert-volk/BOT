import Foundation

struct ChatTurn: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    var text: String
    var date = Date()
    /// True for email conversations: kept out of anything sent to Claude.
    var isPrivate: Bool? = nil
}

/// A "brain" turns what you said into a reply, streamed as text deltas so BOT can start speaking
/// after the first sentence instead of waiting for the whole answer.
protocol Brain {
    var displayName: String { get }
    func respond(system: String, history: [ChatTurn], user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
    /// One-shot, non-streamed completion (used for background fact extraction).
    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String
    func prewarm(system: String)
}

extension Brain {
    func prewarm(system: String) {}
}

enum BrainError: LocalizedError {
    case unavailable(String)
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .http(let code, let msg): return "Claude error \(code): \(msg)"
        }
    }
}

enum BrainFactory {
    /// Why Apple's on-device model can't be used right now, or nil if it can.
    static func appleUnavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleBrain.unavailableReason()
        }
        return "Needs iOS 26 or later."
        #else
        return "This build was made without Apple Intelligence support."
        #endif
    }

    /// Apple's on-device model if this iPhone has it, whichever brain you chose. Used for email, which never leaves the phone.
    static func onDeviceBrain() -> Brain? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleBrain.unavailableReason() == nil { return AppleBrain() }
        #endif
        return nil
    }

    static func make(choice: BrainChoice, claudeKey: String?, webSearch: Bool) -> Brain {
        func apple() -> Brain? {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), AppleBrain.unavailableReason() == nil { return AppleBrain() }
            #endif
            return nil
        }
        func claude() -> Brain? {
            guard let k = claudeKey, !k.isEmpty else { return nil }
            return ClaudeBrain(apiKey: k, nativeSearch: webSearch)
        }
        switch choice {
        case .apple: return apple() ?? BasicBrain(note: appleUnavailableReason())
        case .claude: return claude() ?? BasicBrain(note: "No Claude API key set.")
        case .basic: return BasicBrain(note: nil)
        case .auto:
            return apple() ?? claude() ?? BasicBrain(note: appleUnavailableReason())
        }
    }
}

enum PromptBuilder {
    static func system(prefs: Preferences, facts: String, userName: String?, calendar: String = "") -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        var s = """
        You are \(prefs.botName), a voice assistant talking out loud with one person through their phone. \
        \(prefs.personality.instruction) \
        Speak the way a natural American woman talks: relaxed, with contractions, in plain spoken sentences. \
        Never use markdown, bullet points, lists, emojis, asterisks or headings, because your words are read aloud. \
        \(prefs.replyLength.instruction) \
        Respond right away to what they said, and occasionally ask one short, natural follow-up question. \
        Don't announce that you are an AI unless asked, and never say you can't remember: use the facts below naturally, \
        like a friend would, without reciting them. If they correct a fact, accept it gracefully. \
        You can look things up: when live weather or web search results appear below, answer from them and don't claim you can't browse. Otherwise answer from your own knowledge and say when you're unsure about recent events. \
        You can show things on their screen. If they ask to see a picture, photo, image, map, weather chart or drawing, never say you can't: reply with one short sentence and end with exactly one tag: [[images: search words]] for web pictures, [[map: place]] for a map, [[forecast: city or leave empty]] for a weather chart, [[draw: what to draw]] for a diagram, or [[myphotos: search words]] to search THEIR OWN photo albums (they set that up under the menu, Documents, Add photo albums; if they haven't, tell them to do that, and never say you can't access their photos). Never read a tag aloud or explain it. \
        Current date and time: \(df.string(from: Date())).
        """
        s += prefs.metric
            ? " Always use metric units when you mention measurements: kilometers, meters, kilograms, liters and degrees Celsius, never miles, pounds or Fahrenheit, unless they ask otherwise."
            : " Use US units (miles, pounds, Fahrenheit) unless they ask otherwise."
        if let name = userName { s += " The person's name is \(name); use it now and then, not every reply." }
        if !facts.isEmpty { s += "\n\nWhat you know about them:\n\(facts)" }
        if !calendar.isEmpty { s += "\n\nTheir calendar (next two days):\n\(calendar)" }
        return s
    }

    /// Flattens recent turns into a transcript for engines that take a single prompt (Apple on-device).
    static func transcriptPrompt(history: [ChatTurn], user: String, limitTurns: Int = 8) -> String {
        let recent = history.suffix(limitTurns)
        if recent.isEmpty { return user }
        var lines = recent.map { ($0.role == .user ? "Them: " : "You: ") + $0.text }
        lines.append("Them: \(user)")
        return "Conversation so far:\n" + lines.joined(separator: "\n") + "\n\nReply as You, to their last message."
    }
}
