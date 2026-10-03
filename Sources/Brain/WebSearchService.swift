import Foundation

/// Free web search with no API key or account: DuckDuckGo's HTML results, falling back to Wikipedia.
/// Only the search words leave the phone. Results are handed to the brain as "live data" to answer from.
struct WebSearchService {
    private struct Hit {
        var title: String
        var snippet: String
        var source: String
    }

    // MARK: Intent

    /// Returns the query to search for, or nil if this utterance doesn't need the web.
    static func query(for text: String, basic: Bool) -> String? {
        func matches(_ pattern: String, _ s: String) -> Bool {
            s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let explicit = #"\b(search|look up|google|look it up|find out|browse)\b"#
        let recency = #"\b(latest|news|headlines|currently|right now|this week|recent|recently|score|who won|stock price|price of|what happened|release date|who is the (current|new)|how much (is|does|are))\b"#
        let factual = #"^(who|what|when|where|how many|how tall|how old|how far|tell me about)\b"#
        let personal = #"\b(my|me|you|your|i)\b"#

        let wants = matches(explicit, text) || matches(recency, text)
            || (basic && matches(factual, text) && !matches(personal, text))
        guard wants else { return nil }

        var q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^(?:hey |ok |okay )?(?:can you |could you |would you |please |will you )*(?:search(?: the web| online| the internet)?(?: for)?|look up|google|find out(?: about)?|browse for|tell me about)\s+"#
        q = q.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
        return q.count >= 2 ? q : nil
    }

    // MARK: Search

    func search(_ query: String) async -> LookupResult {
        var hits = (try? await duckDuckGo(query)) ?? []
        if hits.isEmpty { hits = (try? await wikipedia(query)) ?? [] }
        guard !hits.isEmpty else {
            return .failed("I couldn't find anything online for that, or I couldn't reach the internet.")
        }

        let top = hits.prefix(4)
        var facts = "Web search results for \"\(query)\" (use these to answer; if they don't answer it, say so):\n"
        for (i, h) in top.enumerated() {
            facts += "\(i + 1). \(h.title): \(h.snippet.prefix(220)) (\(h.source))\n"
        }

        let best = top[top.startIndex]
        var spoken = "Here's what I found. \(best.title). \(best.snippet.prefix(260))"
        if let last = spoken.lastIndex(where: { ".!?".contains($0) }), spoken.distance(from: last, to: spoken.endIndex) < 80 {
            spoken = String(spoken[...last])
        }
        return .ok(spoken: spoken, facts: facts)
    }

    // MARK: DuckDuckGo

    private func duckDuckGo(_ query: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [.init(name: "q", value: query)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        let titles = Self.captures(#"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#, in: html, groups: 2)
        let snippets = Self.captures(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: html, groups: 1)

        var out: [Hit] = []
        for (i, t) in titles.enumerated() where i < snippets.count {
            let href = t[0]
            if href.contains("duckduckgo.com/y.js") { continue }   // ads
            let title = Self.clean(t[1])
            let snippet = Self.clean(snippets[i][0])
            guard !title.isEmpty, !snippet.isEmpty else { continue }
            out.append(Hit(title: title, snippet: snippet, source: Self.domain(from: href)))
            if out.count >= 5 { break }
        }
        return out
    }

    // MARK: Wikipedia fallback

    private func wikipedia(_ query: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: query),
            .init(name: "gsrlimit", value: "3"), .init(name: "prop", value: "extracts"),
            .init(name: "exintro", value: "1"), .init(name: "explaintext", value: "1"),
            .init(name: "exchars", value: "500"),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        return pages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            .compactMap { p in
                guard let title = p["title"] as? String, let extract = p["extract"] as? String, !extract.isEmpty else { return nil }
                return Hit(title: title, snippet: extract.replacingOccurrences(of: "\n", with: " "), source: "wikipedia.org")
            }
    }

    // MARK: Parsing helpers

    private static func captures(_ pattern: String, in s: String, groups: Int) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1...groups).map { g in
                let r = m.range(at: g)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&hellip;": "…"]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func domain(from href: String) -> String {
        var link = href
        if let r = href.range(of: "uddg=") {
            let encoded = String(href[r.upperBound...]).components(separatedBy: "&").first ?? ""
            link = encoded.removingPercentEncoding ?? encoded
        }
        if link.hasPrefix("//") { link = "https:" + link }
        return URL(string: link)?.host?.replacingOccurrences(of: "www.", with: "") ?? "web"
    }
}
