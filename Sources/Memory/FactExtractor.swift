import Foundation

/// Turns conversation into durable facts. Two layers:
///  1. `heuristic` — instant regex rules that work with any brain (even "Basic").
///  2. `llmPrompt`/`parse` — the active AI brain reads the exchange and lists new facts.
enum FactExtractor {
    typealias Extracted = (text: String, category: FactCategory)

    // MARK: Heuristic layer

    // Literal words are matched case-insensitively via (?i:...); names stay case-sensitive ([A-Z]) so that
    // "my wife is tired" is not mistaken for a name. The speech recognizer capitalizes proper nouns.
    private static let skip = #"(?!(?:it|that|this|you|them|him|her|when|how|to|the idea)\b)"#
    private static let rules: [(pattern: String, category: FactCategory, format: String)] = [
        (#"(?i:\bmy name is) ([A-Z][\w'’-]+)"#, .identity, "Name is $1"),
        (#"(?i:\bcall me) ([A-Z][\w'’-]+)"#, .identity, "Likes to be called $1"),
        (#"(?i:\bi(?:'m| am) from) ([A-Z][\w ,'’.-]{2,40})"#, .home, "Is from $1"),
        (#"(?i:\bi live in) ([A-Z][\w ,'’.-]{2,40})"#, .home, "Lives in $1"),
        (#"(?i:\bi work) (?i:(as|at|for|in)) (?i:an? |the )?([\w &'’.-]{3,50})"#, .work, "Works $1 $2"),
        (#"(?i:\bmy) (?i:(wife|husband|partner|girlfriend|boyfriend|son|daughter|mom|mother|dad|father|brother|sister|dog|cat|boss)) (?i:(?:is |was )?(?:named|called)) ([A-Z][\w'’-]+)"#, .family, "Their $1 is named $2"),
        (#"(?i:\bmy) (?i:(wife|husband|partner|girlfriend|boyfriend|son|daughter|mom|mother|dad|father|brother|sister|dog|cat))(?i:'s name is| is|'s) ([A-Z][\w'’-]+)"#, .family, "Their $1 is named $2"),
        (#"(?i:\bi (?:really )?(?:love|like|enjoy|adore|prefer)) "# + skip + #"([\w &'’-]{3,50})"#, .preferences, "Likes $1"),
        (#"(?i:\bi (?:really )?(?:hate|dislike|can't stand)) "# + skip + #"([\w &'’-]{3,50})"#, .preferences, "Dislikes $1"),
        (#"(?i:\bmy favorite) ([\w ]{3,25}) (?i:is) ([\w &'’-]{2,40})"#, .preferences, "Favorite $1 is $2"),
        (#"(?i:\bmy birthday is) ([\w ,]{3,25})"#, .identity, "Birthday is $1"),
    ]

    static func heuristic(_ utterance: String) -> [Extracted] {
        var out: [Extracted] = []
        let clauses = utterance.components(separatedBy: CharacterSet(charactersIn: ".!?;"))
        for clause in clauses {
            for rule in rules {
                guard let re = try? NSRegularExpression(pattern: rule.pattern) else { continue }
                let ns = clause as NSString
                guard let m = re.firstMatch(in: clause, range: NSRange(location: 0, length: ns.length)) else { continue }
                var text = rule.format
                for g in stride(from: m.numberOfRanges - 1, through: 1, by: -1) {
                    let r = m.range(at: g)
                    let piece = r.location == NSNotFound ? "" : ns.substring(with: r)
                    text = text.replacingOccurrences(of: "$\(g)", with: piece.trimmingCharacters(in: .whitespaces))
                }
                out.append((text, rule.category))
            }
        }
        return out
    }

    // MARK: Explicit commands

    /// "remember that I'm allergic to peanuts" → ("I'm allergic to peanuts")
    static func rememberRequest(_ utterance: String) -> String? {
        let lower = utterance.lowercased()
        for prefix in ["remember that ", "please remember that ", "remember this: ", "remember "] {
            if lower.hasPrefix(prefix) {
                let rest = String(utterance.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return rest.count >= 4 ? Self.thirdPerson(rest) : nil
            }
        }
        return nil
    }

    static func forgetRequest(_ utterance: String) -> String? {
        let lower = utterance.lowercased()
        for prefix in ["forget that ", "please forget that ", "forget about "] {
            if lower.hasPrefix(prefix) {
                return String(utterance.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func isForgetEverything(_ utterance: String) -> Bool {
        let l = utterance.lowercased()
        return l.contains("forget everything about me") || l.contains("erase your memory") || l.contains("clear your memory")
    }

    /// Rewrites first person into a neutral third-person fact ("I'm allergic" → "Is allergic").
    private static func thirdPerson(_ s: String) -> String {
        var t = s
        let swaps: [(String, String)] = [
            ("i'm ", "is "), ("i am ", "is "), ("i've ", "has "), ("i have ", "has "),
            ("i ", ""), ("my ", "their "), ("me ", "them "),
        ]
        let lower = t.lowercased()
        for (a, b) in swaps where lower.hasPrefix(a) {
            t = b + t.dropFirst(a.count)
            break
        }
        return t.capitalizedFirst
    }

    // MARK: LLM layer

    static let systemPrompt = """
    You extract durable personal facts about the USER from a chat. Output only NEW facts that are not already known. \
    One per line, in the form `category: fact`, where category is one of: identity, family, work, home, preferences, \
    interests, goals, health, other. Write each fact short and in third person without the word "User" \
    (examples: `identity: Name is Sam`, `family: Has a dog named Max`, `preferences: Likes strong black coffee`, \
    `work: Works as a nurse`). \
    Ignore temporary things (mood, what they are doing right now), questions, opinions about the weather, and \
    anything only the assistant said. If there is nothing new and lasting, output exactly: NONE
    """

    static func prompt(known: String, user: String, assistant: String) -> String {
        """
        Already known:
        \(known.isEmpty ? "(nothing yet)" : known)

        The user said: "\(user)"
        The assistant replied: "\(assistant)"

        New facts:
        """
    }

    static func parse(_ output: String) -> [Extracted] {
        var result: [Extracted] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•*0123456789.) "))
            if line.isEmpty || line.uppercased().hasPrefix("NONE") { continue }
            var category = FactCategory.other
            if let colon = line.firstIndex(of: ":") {
                let head = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                if let c = FactCategory(rawValue: head) {
                    category = c
                    line = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if line.count >= 4 { result.append((line.capitalizedFirst, category)) }
            if result.count >= 3 { break }
        }
        return result
    }

    /// Cheap gate so we don't spend a model call on "what's the weather".
    static func worthExtracting(_ utterance: String) -> Bool {
        let words = utterance.split(separator: " ")
        guard words.count >= 4 else { return false }
        let l = " " + utterance.lowercased() + " "
        return [" i ", " i'm ", " i've ", " i'd ", " i'll ", " my ", " me ", " we ", " our ", " mine "].contains { l.contains($0) }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
