import Foundation

/// Web search with page reading. Sources, in order:
///  1. Brave Search API, if you added a key in Settings (most reliable, "Google-style" results).
///  2. DuckDuckGo's HTML results (free, no key).
///  3. Wikipedia (free, no key) as a last resort.
/// The top pages are then fetched and read so BOT answers from real content, not just snippets.
/// Only your search words go to the search provider; page fetches contact those sites directly.
struct WebSearchService {
    var braveKey: String?

    private struct Hit {
        var title: String
        var snippet: String
        var url: String
        var source: String
        var excerpt: String = ""
    }

    // MARK: Intent

    /// Returns the query to search for, or nil if this utterance doesn't need the web.
    static func query(for text: String, basic: Bool) -> String? {
        func matches(_ pattern: String, _ s: String) -> Bool {
            s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let explicit = #"\b(search|look up|google|look it up|find out|browse)\b"#
        let recency = #"\b(latest|news|headlines|currently|right now|this week|recent|recently|score|who won|stock price|price of|what happened|release date|who is the (current|new)|how much (is|does|are)|open now|near me|reviews? of)\b"#
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
        var hits: [Hit] = []
        if let key = braveKey, !key.isEmpty { hits = (try? await brave(query, key: key)) ?? [] }
        if hits.isEmpty { hits = (try? await duckDuckGo(query)) ?? [] }
        if hits.isEmpty { hits = (try? await wikipedia(query)) ?? [] }
        guard !hits.isEmpty else {
            return .failed("I couldn't find anything online for that, or I couldn't reach the internet.")
        }

        var top = Array(hits.prefix(4))
        await readPages(&top)

        var facts = "Web search results for \"\(query)\" (answer from these; if they don't answer it, say so; mention the source when useful):\n"
        for (i, h) in top.enumerated() {
            facts += "\(i + 1). \(h.title) (\(h.source)): \(h.snippet.prefix(200))\n"
            if !h.excerpt.isEmpty { facts += "   Page text: \(h.excerpt)\n" }
        }

        let best = top[0]
        var spoken = "Here's what I found. \(best.title). \(best.snippet.prefix(260))"
        if let last = spoken.lastIndex(where: { ".!?".contains($0) }), spoken.distance(from: last, to: spoken.endIndex) < 80 {
            spoken = String(spoken[...last])
        }
        return .ok(spoken: spoken, facts: facts)
    }

    // MARK: Page reading

    /// Fetches the first two non-Wikipedia-snippet pages in parallel and stores a short text excerpt.
    private func readPages(_ hits: inout [Hit]) async {
        let targets = hits.indices.prefix(2)
        let results: [(Int, String)] = await withTaskGroup(of: (Int, String).self) { group in
            for i in targets {
                let url = hits[i].url
                group.addTask { (i, await Self.pageExcerpt(url)) }
            }
            var out: [(Int, String)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (i, text) in results { hits[i].excerpt = text }
    }

    private static func pageExcerpt(_ urlString: String) async -> String {
        guard let url = URL(string: urlString), url.scheme == "https" else { return "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html"),
              data.count < 2_000_000,
              var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return "" }

        for block in ["script", "style", "nav", "header", "footer", "aside", "noscript", "svg", "form"] {
            html = html.replacingOccurrences(of: "<\(block)[^>]*>.*?</\(block)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        let paragraphs = captures(#"<p[^>]*>(.*?)</p>"#, in: html, groups: 1)
            .map { clean($0[0]) }
            .filter { $0.count > 60 }
        var text = paragraphs.joined(separator: " ")
        if text.isEmpty { text = clean(html) }
        return String(text.prefix(650))
    }

    // MARK: Brave

    private func brave(_ query: String, key: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "count", value: "5")]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = (root["web"] as? [String: Any])?["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let title = r["title"] as? String, let url = r["url"] as? String else { return nil }
            let desc = Self.clean(r["description"] as? String ?? "")
            return Hit(title: Self.clean(title), snippet: desc, url: url, source: URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "web")
        }
    }

    // MARK: DuckDuckGo

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private func duckDuckGo(_ query: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [.init(name: "q", value: query)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
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
            let link = Self.realURL(from: href)
            out.append(Hit(title: title, snippet: snippet, url: link,
                           source: URL(string: link)?.host?.replacingOccurrences(of: "www.", with: "") ?? "web"))
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
                let slug = title.replacingOccurrences(of: " ", with: "_")
                var h = Hit(title: title, snippet: extract.replacingOccurrences(of: "\n", with: " "),
                            url: "https://en.wikipedia.org/wiki/\(slug)", source: "wikipedia.org")
                h.excerpt = ""   // the extract already is the page intro
                return h
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
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&hellip;": "…", "&rsquo;": "'", "&ldquo;": "\"", "&rdquo;": "\""]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DuckDuckGo wraps result links in a redirect (`//duckduckgo.com/l/?uddg=<encoded>`).
    private static func realURL(from href: String) -> String {
        var link = href
        if let r = href.range(of: "uddg=") {
            let encoded = String(href[r.upperBound...]).components(separatedBy: "&").first ?? ""
            link = encoded.removingPercentEncoding ?? encoded
        }
        if link.hasPrefix("//") { link = "https:" + link }
        return link
    }
}
