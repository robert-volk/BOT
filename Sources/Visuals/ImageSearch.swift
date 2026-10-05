import Foundation

struct WebImage: Identifiable {
    let id = UUID()
    let title: String
    let thumbURL: URL
    let pageURL: URL?
    let credit: String
}

/// Pictures from the web without any account: Wikipedia's article images and Wikimedia Commons (freely licensed,
/// with credits). If you've saved a Brave Search key, Brave's image search is used first for broader results.
enum ImageSearchService {
    static func search(_ query: String, braveKey: String?, limit: Int = 8) async -> [WebImage] {
        var found: [WebImage] = []
        if let key = braveKey, !key.isEmpty { found += await brave(query, key: key) }
        if found.count < limit { found += await wikipedia(query) }
        if found.count < limit { found += await commons(query) }
        var seen = Set<String>()
        return Array(found.filter { seen.insert($0.thumbURL.absoluteString).inserted }.prefix(limit))
    }

    // MARK: Helpers

    private static func json(_ url: URL, headers: [String: String] = [:]) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("BOT-iOS/1.0 (personal assistant app)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func secureURL(_ s: String?) -> URL? {
        guard var t = s, !t.isEmpty else { return nil }
        if t.hasPrefix("//") { t = "https:" + t }
        if t.hasPrefix("http://") { t = "https://" + t.dropFirst(7) }
        return t.hasPrefix("https://") ? URL(string: t) : nil
    }

    private static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Brave (optional key)

    private static func brave(_ query: String, key: String) async -> [WebImage] {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/images/search")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "count", value: "8"), .init(name: "safesearch", value: "strict")]
        guard let url = c.url,
              let root = await json(url, headers: ["X-Subscription-Token": key, "Accept": "application/json"]),
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let thumb = secureURL((r["thumbnail"] as? [String: Any])?["src"] as? String) else { return nil }
            let title = (r["title"] as? String) ?? query
            return WebImage(title: title, thumbURL: thumb, pageURL: secureURL(r["url"] as? String),
                            credit: (r["source"] as? String).map { "From " + $0 } ?? "Brave Search")
        }
    }

    // MARK: Wikipedia article images

    private static func wikipedia(_ query: String) async -> [WebImage] {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: query), .init(name: "gsrlimit", value: "8"),
            .init(name: "prop", value: "pageimages|info"), .init(name: "piprop", value: "thumbnail"),
            .init(name: "pithumbsize", value: "1000"), .init(name: "inprop", value: "url"),
        ]
        guard let url = c.url, let root = await json(url),
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        return pages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            .compactMap { p in
                guard let thumb = secureURL((p["thumbnail"] as? [String: Any])?["source"] as? String) else { return nil }
                return WebImage(title: (p["title"] as? String) ?? query, thumbURL: thumb,
                                pageURL: secureURL(p["fullurl"] as? String), credit: "Wikipedia (free-licensed image)")
            }
    }

    // MARK: Wikimedia Commons files

    private static func commons(_ query: String) async -> [WebImage] {
        var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrnamespace", value: "6"),
            .init(name: "gsrsearch", value: query + " filetype:bitmap"), .init(name: "gsrlimit", value: "8"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|extmetadata"), .init(name: "iiurlwidth", value: "1000"),
        ]
        guard let url = c.url, let root = await json(url),
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        return pages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            .compactMap { p in
                guard let info = (p["imageinfo"] as? [[String: Any]])?.first,
                      let thumb = secureURL(info["thumburl"] as? String) else { return nil }
                let meta = info["extmetadata"] as? [String: Any]
                let artist = ((meta?["Artist"] as? [String: Any])?["value"] as? String).map(plain) ?? ""
                let license = ((meta?["LicenseShortName"] as? [String: Any])?["value"] as? String) ?? ""
                let credit = [artist, license].filter { !$0.isEmpty }.joined(separator: " · ")
                var title = (p["title"] as? String) ?? query
                if title.hasPrefix("File:") { title = String(title.dropFirst(5)) }
                title = (title as NSString).deletingPathExtension
                return WebImage(title: title, thumbURL: thumb, pageURL: secureURL(info["descriptionurl"] as? String),
                                credit: credit.isEmpty ? "Wikimedia Commons" : credit + " · Wikimedia Commons")
            }
    }
}
