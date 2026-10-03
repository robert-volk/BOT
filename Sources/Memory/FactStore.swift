import Foundation

enum FactCategory: String, Codable, CaseIterable, Identifiable {
    case identity, family, work, home, preferences, interests, goals, health, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .identity: return "person.fill"
        case .family: return "heart.fill"
        case .work: return "briefcase.fill"
        case .home: return "house.fill"
        case .preferences: return "star.fill"
        case .interests: return "sparkles"
        case .goals: return "flag.fill"
        case .health: return "cross.case.fill"
        case .other: return "tag.fill"
        }
    }
}

struct Fact: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var category: FactCategory
    var created = Date()
    var lastMentioned = Date()
    var mentions = 1
    var pinned = false
}

/// Everything BOT has learned about you. Stored only on this device (Application Support/BOT/facts.json).
@MainActor
final class FactStore: ObservableObject {
    @Published private(set) var facts: [Fact] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BOT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("facts.json")
        load()
    }

    // MARK: Queries

    var userName: String? {
        for f in facts where f.category == .identity {
            if let r = f.text.range(of: #"(?i)\bname is ([A-Za-z][\w'’-]*)"#, options: .regularExpression) {
                let match = String(f.text[r])
                if let last = match.split(separator: " ").last { return String(last) }
            }
        }
        return nil
    }

    /// Facts formatted for the system prompt, most useful first, capped to keep the prompt small and fast.
    func promptBlock(limit: Int = 40) -> String {
        let ranked = facts.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let sa = Double(a.mentions) + a.lastMentioned.timeIntervalSince1970 / 1e9
            let sb = Double(b.mentions) + b.lastMentioned.timeIntervalSince1970 / 1e9
            return sa > sb
        }
        return ranked.prefix(limit).map { "- \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Mutations

    @discardableResult
    func add(_ text: String, category: FactCategory = .other, pinned: Bool = false) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•*\"")))
        guard clean.count >= 4, clean.count <= 200 else { return false }

        if let idx = facts.firstIndex(where: { Self.similar($0.text, clean) }) {
            facts[idx].mentions += 1
            facts[idx].lastMentioned = Date()
            if clean.count > facts[idx].text.count { facts[idx].text = clean }
            if pinned { facts[idx].pinned = true }
            save()
            return false
        }
        facts.append(Fact(text: clean, category: category, pinned: pinned))
        save()
        return true
    }

    func update(_ fact: Fact, text: String) {
        guard let idx = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        facts[idx].text = text
        save()
    }

    func togglePin(_ fact: Fact) {
        guard let idx = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        facts[idx].pinned.toggle()
        save()
    }

    func remove(_ fact: Fact) {
        facts.removeAll { $0.id == fact.id }
        save()
    }

    func remove(at offsets: IndexSet, in list: [Fact]) {
        let ids = offsets.map { list[$0].id }
        facts.removeAll { ids.contains($0.id) }
        save()
    }

    /// Removes facts containing the phrase ("forget that I like jazz"). Returns how many were removed.
    @discardableResult
    func forget(matching phrase: String) -> Int {
        let words = Self.words(phrase)
        guard !words.isEmpty else { return 0 }
        let before = facts.count
        facts.removeAll { f in
            let fw = Self.words(f.text)
            return !fw.isDisjoint(with: words) && Double(fw.intersection(words).count) / Double(words.count) >= 0.5
        }
        if facts.count != before { save() }
        return before - facts.count
    }

    func clear() {
        facts.removeAll()
        save()
    }

    // MARK: Similarity

    private static let stop: Set<String> = ["the", "a", "an", "is", "are", "was", "of", "and", "to", "in", "on", "at",
                                            "user", "users", "has", "have", "likes", "like", "that", "i", "my", "me"]

    static func words(_ s: String) -> Set<String> {
        let parts = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }
        return Set(parts)
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let wa = words(a), wb = words(b)
        if wa.isEmpty || wb.isEmpty { return a.lowercased() == b.lowercased() }
        let inter = Double(wa.intersection(wb).count)
        let union = Double(wa.union(wb).count)
        return inter / union >= 0.7 || inter / Double(min(wa.count, wb.count)) >= 0.9
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Fact].self, from: data) else { return }
        facts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
