import Foundation

struct NoteItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var date = Date()
}

struct ListsData: Codable {
    var lists: [String: [String]] = [:]
    var notes: [NoteItem] = []
    // Optional so lists.json from earlier versions still loads.
    var meetings: [MeetingNote]?
    var journal: [JournalEntry]?
    var parking: ParkingSpot?
}

/// What the user asked to do with lists / notes.
enum ListIntent {
    case add(items: [String], list: String)
    case read(list: String)
    case remove(item: String, list: String)
    case clear(list: String)
    case note(String)
    case readNotes
    case searchNotes(String)

    // MARK: Parsing

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func parse(_ raw: String) -> ListIntent? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))

        if let g = firstMatch(#"^(?:please )?(?:take|make|write|save|jot|add)(?: down)?\s+(?:a )?note\b(?: to self)?[:,]?\s*(.+)$"#, in: t)
            ?? firstMatch(#"^note to self[:,]?\s*(.+)$"#, in: t) {
            return .note(g[0])
        }
        if let g = firstMatch(#"what did i (?:note|write|save|jot)(?: down)? (?:about|on) (.+)$"#, in: t) { return .searchNotes(g[0]) }
        if firstMatch(#"\b(?:read|show|what are|what'?s in|list|go over)\b.*\b(?:my )?notes\b"#, in: t) != nil { return .readNotes }

        if let g = firstMatch(#"^(?:please )?(?:add|put)\s+(.+?)\s+(?:to|on|onto|in)\s+(?:my |the |our )?(.+?)\s+list$"#, in: t) {
            return .add(items: splitItems(g[0]), list: normalize(g[1]))
        }
        if let g = firstMatch(#"^(?:please )?add (?:to|on) (?:my |the |our )?(.+?) list[:,]?\s+(.+)$"#, in: t) {
            return .add(items: splitItems(g[1]), list: normalize(g[0]))
        }
        if let g = firstMatch(#"^(?:please )?(?:remove|delete|take|cross off|check off|mark off)\s+(.+?)\s+(?:from|off|on)\s+(?:my |the |our )?(.+?) list$"#, in: t) {
            return .remove(item: g[0], list: normalize(g[1]))
        }
        if let g = firstMatch(#"^(?:please )?(?:clear|empty|erase)\s+(?:out )?(?:my |the |our )?(.+?) list$"#, in: t) {
            return .clear(list: normalize(g[0]))
        }
        if let g = firstMatch(#"\b(?:what'?s|what is|read|show|tell me|check|go over)\b.{0,25}?(?:my |our )([A-Za-z-]+(?: [A-Za-z-]+)?) list\b"#, in: t) {
            return .read(list: normalize(g[0]))
        }
        return nil
    }

    static func splitItems(_ s: String) -> [String] {
        s.replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.capitalizedFirst }
    }

    /// "groceries" / "shopping" -> "grocery", "to do" / "tasks" -> "to-do".
    static func normalize(_ name: String) -> String {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if ["groceries", "grocery", "shopping", "food"].contains(n) { return "grocery" }
        if ["to do", "to-do", "todo", "tasks", "task", "chores"].contains(n) { return "to-do" }
        return n
    }
}

/// Voice-managed lists and notes, stored only on this phone (Application Support/BOT/lists.json).
@MainActor
final class ListStore: ObservableObject {
    @Published private(set) var data = ListsData()
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BOT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("lists.json")
        if let d = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(ListsData.self, from: d) {
            data = decoded
        }
    }

    var listNames: [String] { data.lists.keys.sorted() }

    func items(in list: String) -> [String] { data.lists[list] ?? [] }

    @discardableResult
    func add(_ items: [String], to list: String) -> [String] {
        var current = data.lists[list] ?? []
        var added: [String] = []
        for item in items where !current.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
            current.append(item)
            added.append(item)
        }
        data.lists[list] = current
        save()
        return added
    }

    func remove(_ item: String, from list: String) -> Bool {
        guard var current = data.lists[list] else { return false }
        let target = item.lowercased()
        guard let idx = current.firstIndex(where: { $0.lowercased() == target })
                ?? current.firstIndex(where: { $0.lowercased().contains(target) || target.contains($0.lowercased()) }) else { return false }
        current.remove(at: idx)
        data.lists[list] = current.isEmpty ? nil : current
        save()
        return true
    }

    func removeItem(at offsets: IndexSet, in list: String) {
        guard var current = data.lists[list] else { return }
        current.remove(atOffsets: offsets)
        data.lists[list] = current.isEmpty ? nil : current
        save()
    }

    func clear(_ list: String) {
        data.lists[list] = nil
        save()
    }

    func addNote(_ text: String) {
        data.notes.insert(NoteItem(text: text.capitalizedFirst), at: 0)
        save()
    }

    func deleteNotes(at offsets: IndexSet) {
        data.notes.remove(atOffsets: offsets)
        save()
    }

    func searchNotes(_ topic: String) -> [NoteItem] {
        let words = FactStore.words(topic)
        guard !words.isEmpty else { return [] }
        return data.notes.filter { !FactStore.words($0.text).isDisjoint(with: words) }
    }

    // MARK: Meetings, journal, parking

    var meetings: [MeetingNote] { data.meetings ?? [] }
    var journal: [JournalEntry] { data.journal ?? [] }

    func addMeeting(_ m: MeetingNote) {
        var list = data.meetings ?? []
        list.append(m)
        data.meetings = list
        save()
    }

    func deleteMeeting(_ m: MeetingNote) {
        data.meetings = (data.meetings ?? []).filter { $0.id != m.id }
        save()
    }

    func addJournal(_ text: String, mood: String?) {
        var list = data.journal ?? []
        list.append(JournalEntry(text: text, mood: mood))
        data.journal = list
        save()
    }

    func deleteJournal(_ e: JournalEntry) {
        data.journal = (data.journal ?? []).filter { $0.id != e.id }
        save()
    }

    func setParking(_ spot: ParkingSpot) {
        data.parking = spot
        save()
    }

    func clearParking() {
        data.parking = nil
        save()
    }

    // MARK: Spoken answers

    func spokenList(_ list: String) -> String {
        let items = items(in: list)
        guard !items.isEmpty else { return "Your \(list) list is empty." }
        let count = items.count == 1 ? "one item" : "\(items.count) items"
        return "Your \(list) list has \(count): " + Self.joined(items) + "."
    }

    func spokenNotes(_ notes: [NoteItem]) -> String {
        guard !notes.isEmpty else { return "I don't have any notes like that." }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        let parts = notes.prefix(3).map { "\($0.text), from \(Calendar.current.isDateInToday($0.date) ? "today" : f.string(from: $0.date))" }
        return (notes.count == 1 ? "You have one note. " : "You have \(notes.count) notes. Latest first. ") + parts.joined(separator: ". ") + "."
    }

    static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }
}
