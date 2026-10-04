import Foundation

/// News providers for the daily briefing. Both are free and need no key.
///  - NPR: its public RSS feed.
///  - CNN: CNN's own RSS feed stopped updating in 2023 and is http-only, so this uses Google News' CNN-only
///    feed (live, https), which carries the latest CNN headlines.
enum NewsSource: String, CaseIterable {
    case npr, cnn

    var name: String { self == .npr ? "NPR" : "CNN" }

    var url: String {
        switch self {
        case .npr: return "https://feeds.npr.org/1001/rss.xml"
        case .cnn: return "https://news.google.com/rss/search?q=when:1d+source:CNN&hl=en-US&gl=US&ceid=US:en"
        }
    }
}

/// Pieces of the daily briefing: the trigger phrases and the news headlines.
enum BriefingService {
    static func isBriefingRequest(_ text: String) -> Bool {
        let pattern = #"^(?:hey |ok |okay )?(?:good morning|good afternoon|good evening|morning|brief me|give me (?:my |the )?(?:daily )?(?:briefing|brief|rundown|update)|(?:daily|morning) briefing|what'?s my day (?:look like|looking like)|what does my day look like|catch me up)\b"#
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Top headlines from each source, in the order given. Sources that fail are left out.
    static func headlines(from sources: [NewsSource], count: Int = 3) async -> [(source: String, titles: [String])] {
        await withTaskGroup(of: (Int, String, [String]).self) { group in
            for (i, s) in sources.enumerated() {
                group.addTask { (i, s.name, await fetch(s, count: count)) }
            }
            var results: [(Int, String, [String])] = []
            for await r in group { results.append(r) }
            return results
                .sorted { $0.0 < $1.0 }
                .filter { !$0.2.isEmpty }
                .map { (source: $0.1, titles: $0.2) }
        }
    }

    private static func fetch(_ source: NewsSource, count: Int) async -> [String] {
        guard let url = URL(string: source.url) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 7
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"<item>.*?<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>"#,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = xml as NSString
        let titles: [String] = re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var t = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if source == .cnn {
                // Google News appends the outlet: "Headline | CNN Politics - CNN".
                for _ in 0..<2 {
                    t = t.replacingOccurrences(of: #"\s*[-|–—]\s*CNN(?:\s[A-Za-z ]+)?$"#, with: "", options: .regularExpression)
                }
            }
            return t.isEmpty ? nil : t
        }
        return Array(titles.prefix(count))
    }

    static func greeting(name: String?) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")
        return name.map { "\(part), \($0)." } ?? "\(part)."
    }
}
