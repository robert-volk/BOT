import Foundation

/// Pieces of the daily briefing: the trigger phrases and the news headlines (NPR's public RSS feed, free, no key).
enum BriefingService {
    static func isBriefingRequest(_ text: String) -> Bool {
        let pattern = #"^(?:hey |ok |okay )?(?:good morning|good afternoon|good evening|morning|brief me|give me (?:my |the )?(?:daily )?(?:briefing|brief|rundown|update)|(?:daily|morning) briefing|what'?s my day (?:look like|looking like)|what does my day look like|catch me up)\b"#
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func headlines(count: Int = 3) async -> [String] {
        guard let url = URL(string: "https://feeds.npr.org/1001/rss.xml") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"<item>.*?<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>"#,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = xml as NSString
        let titles: [String] = re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let t = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
