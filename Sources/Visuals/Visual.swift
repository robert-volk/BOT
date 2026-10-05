import Foundation
import CoreLocation

/// Something BOT shows on screen: web pictures, a map, a forecast chart, or a drawn diagram.
enum Visual: Identifiable {
    case images(query: String, images: [WebImage])
    case map(title: String, coordinate: CLLocationCoordinate2D)
    case forecast(place: String, days: [WeatherService.DayForecast], metric: Bool)
    case diagram(title: String, svg: String)

    var id: String {
        switch self {
        case .images(let q, _): return "images-" + q
        case .map(let t, _): return "map-" + t
        case .forecast(let p, _, _): return "forecast-" + p
        case .diagram(let t, _): return "diagram-" + t
        }
    }

    var title: String {
        switch self {
        case .images(let q, let images): return "\(q.capitalizedFirst) (\(images.count))"
        case .map(let t, _): return t
        case .forecast(let p, _, _): return "7-day forecast, \(p)"
        case .diagram(let t, _): return t
        }
    }
}

/// What the user asked to see.
enum VisualIntent {
    case images(String)
    case map(String)
    case weatherChart(String)
    case diagram(String)
    case myPhotos(String)

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// "can you please show me..." and "let me see..." become "show me ...".
    static func stripPolite(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"^(?:hey,? |ok,? |okay,? )?(?:can|could|would|will) you (?:please )?"#, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"^(?:please )?(?:i(?:'d| would) like to see|let me see|i want to see|i need to see)\b"#, with: "show me",
                                   options: [.regularExpression, .caseInsensitive])
        return t
    }

    static func parse(_ raw: String) -> VisualIntent? {
        let t = stripPolite(raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?")))

        if let g = match(#"\b(?:chart|graph|plot|visuali[sz]e)\b.{0,30}\b(?:weather|forecast|temperatures?)\b(?:\s+(?:in|for)\s+([A-Za-z][A-Za-z .'-]*))?$"#, t) {
            return .weatherChart(g[0].trimmingCharacters(in: .whitespaces))
        }
        if let g = match(#"^(?:please )?(?:show|display|pull up|open|get)\b.{0,12}?\bmap\b(?:\s+(?:of|for|to))?\s*(.*)$"#, t) {
            return .map(g[0].trimmingCharacters(in: .whitespaces))
        }
        if let g = match(#"^(?:please )?(?:draw|sketch|illustrate)\s+(?:me\s+)?(?:a |an |the )?(.+)$"#, t)
            ?? match(#"^(?:please )?(?:make|create|generate|give me)\s+(?:me\s+)?(?:a |an )?(?:diagram|flowchart|infographic|illustration|drawing|sketch)\s+(?:of|for|showing|about|to explain)\s+(.+)$"#, t)
            ?? match(#"^(?:diagram|visuali[sz]e)\s+(.+)$"#, t) {
            return .diagram(g[0])
        }
        if let g = match(#"^what (?:does|do|did) (?:an? |the )?(.+?) look like(?: online)?$"#, t) {
            return .images(g[0])
        }
        if let g = match(#"^(?:please )?(?:show|find|get|pull up|display|look up|search for)\b.{0,15}?\b(?:pictures?|photos?|images?|pics?|graphics?)\b\s+(?:of|for|showing|about)\s+(.+?)\s+(?:online|on the web|from the web|from the internet|on the internet)$"#, t) {
            return .images(g[0])
        }
        return nil
    }
}

/// Keeps a drawn SVG safe to display: no scripts, no outside content.
enum SVGSanitizer {
    static func extract(_ text: String) -> String? {
        guard let start = text.range(of: "<svg", options: .caseInsensitive),
              let end = text.range(of: "</svg>", options: [.caseInsensitive, .backwards]),
              start.lowerBound < end.upperBound else { return nil }
        var svg = String(text[start.lowerBound..<end.upperBound])
        let remove = [
            #"<script[\s\S]*?</script>"#,
            #"<foreignObject[\s\S]*?</foreignObject>"#,
            #"<image[\s\S]*?(?:/>|</image>)"#,
            #"\son\w+\s*=\s*"[^"]*""#,
            #"(?:xlink:)?href\s*=\s*"https?:[^"]*""#,
        ]
        for pattern in remove {
            svg = svg.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return svg
    }
}


/// The AI can put things on screen by ending its reply with a tag such as [[images: eiffel tower]].
/// This removes the tags from the text (so they are never spoken or shown) and remembers what they asked for.
struct VisualTagFilter {
    private var buffer = ""
    private(set) var tags: [VisualIntent] = []

    mutating func feed(_ delta: String) -> String {
        buffer += delta
        var out = ""
        while true {
            if let open = buffer.range(of: "[[") {
                out += buffer[..<open.lowerBound]
                if let close = buffer.range(of: "]]", range: open.upperBound..<buffer.endIndex) {
                    let inner = String(buffer[open.upperBound..<close.lowerBound])
                    if let intent = Self.parse(inner) { tags.append(intent) }
                    buffer = String(buffer[close.upperBound...])
                    continue
                }
                buffer = String(buffer[open.lowerBound...])   // hold the unfinished tag until the rest arrives
                return out
            }
            if buffer.hasSuffix("[") {                         // might be the start of "[["
                out += buffer.dropLast()
                buffer = "["
                return out
            }
            out += buffer
            buffer = ""
            return out
        }
    }

    /// Whatever is left at the end of the reply. An unfinished tag is dropped.
    mutating func flush() -> String {
        let rest = buffer.hasPrefix("[[") ? "" : buffer
        buffer = ""
        return rest
    }

    private static func parse(_ inner: String) -> VisualIntent? {
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let kind = inner[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
        let arg = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        switch kind {
        case "images", "image", "pictures", "photos": return arg.isEmpty ? nil : .images(arg)
        case "map": return .map(arg)
        case "forecast", "chart": return .weatherChart(arg)
        case "draw", "diagram": return arg.isEmpty ? nil : .diagram(arg)
        case "myphotos", "my photos", "photos library", "photolibrary": return .myPhotos(arg)
        default: return nil
        }
    }
}
