import Foundation

/// Fallback with no language model: simple rules. Honest about its limits so the app is still usable
/// (and still learns facts, via the heuristic extractor) on iPhones without Apple Intelligence.
struct BasicBrain: Brain {
    var note: String?
    var displayName: String { "Basic mode" }

    private static let jokes = [
        "Why did the robot go on vacation? It needed to recharge its batteries.",
        "I told my computer I needed a break, and now it won't stop sending me vacation ads.",
        "Why was the robot so calm? It had nerves of steel.",
    ]

    func respond(system: String, history: [ChatTurn], user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        let reply = Self.reply(to: user, system: system)
        return AsyncThrowingStream { c in
            c.yield(reply)
            c.finish()
        }
    }

    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String { "NONE" }

    static func reply(to input: String, system: String) -> String {
        let t = input.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }

        if has("what do you know about me", "what do you remember") {
            let known = system.components(separatedBy: "What you know about them:\n").dropFirst().first ?? ""
            let items = known.split(separator: "\n").prefix(5).map { $0.dropFirst(2) }
            if items.isEmpty { return "Not much yet. Tell me about yourself, and I'll remember it." }
            return "Here's some of what I remember. " + items.joined(separator: ". ") + "."
        }
        if has("my name") && has("what", "who") {
            if let r = system.range(of: "The person's name is ") {
                let name = system[r.upperBound...].prefix { $0.isLetter || $0 == "'" || $0 == "-" }
                if !name.isEmpty { return "Your name is \(name)." }
            }
            return "I don't know your name yet. What should I call you?"
        }
        if has("hello", "hi ", "hey") && t.count < 20 { return "Hey there! What's on your mind?" }
        if has("how are you") { return "I'm doing great, thanks for asking. How about you?" }
        if has("thank") { return "Anytime!" }
        if has("joke") { return jokes.randomElement()! }
        if has("what time") || has("what's the time") {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return "It's \(f.string(from: Date()))."
        }
        if has("what day", "what's the date", "today's date") {
            let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
            return "Today is \(f.string(from: Date()))."
        }
        if has("who are you", "your name") { return "I'm BOT, your voice buddy." }
        if has("bye", "goodnight", "good night") { return "Talk to you later!" }
        return "I'm in basic mode right now, so I can't chat about that, but I'm happy to learn about you. Tell me something about yourself."
    }
}
