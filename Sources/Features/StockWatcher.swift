import Foundation

struct StockWatch: Identifiable, Codable, Equatable {
    var id = UUID()
    var symbol: String
    var name: String
    /// Alert when the price has moved this many percent from the previous day's close.
    var percent: Double
    var rising: Bool = true
    var lastAlertDay: String? = nil
}

struct StockQuote: Equatable {
    var symbol: String
    var name: String
    var price: Double
    var previousClose: Double
    var currency: String
    var dayHigh: Double? = nil
    var dayLow: Double? = nil
    var volume: Double? = nil
    var yearHigh: Double? = nil
    var yearLow: Double? = nil

    var changePercent: Double { previousClose > 0 ? (price - previousClose) / previousClose * 100 : 0 }
}

struct StockMatch: Identifiable, Equatable {
    var symbol: String
    var name: String
    var exchange: String
    var id: String { symbol }
}

/// Free quotes from Yahoo Finance's public chart/search endpoints (no key; may be delayed up to ~15 minutes).
enum StockService {
    private static func get(_ url: URL) async -> Any? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func search(_ text: String) async -> [StockMatch] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              var comps = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "quotesCount", value: "8"),
                            URLQueryItem(name: "newsCount", value: "0")]
        guard let url = comps.url,
              let json = await get(url) as? [String: Any],
              let quotes = json["quotes"] as? [[String: Any]] else { return [] }
        return quotes.compactMap { item in
            guard let symbol = item["symbol"] as? String,
                  let type = item["quoteType"] as? String, ["EQUITY", "ETF"].contains(type) else { return nil }
            let name = (item["longname"] as? String) ?? (item["shortname"] as? String) ?? symbol
            return StockMatch(symbol: symbol, name: name, exchange: (item["exchDisp"] as? String) ?? "")
        }
    }

    static func quote(_ symbol: String) async -> StockQuote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=1d"),
              let json = await get(url) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double else { return nil }
        let previous = (meta["previousClose"] as? Double) ?? (meta["chartPreviousClose"] as? Double) ?? 0
        guard previous > 0 else { return nil }
        let name = (meta["longName"] as? String) ?? (meta["shortName"] as? String) ?? symbol
        return StockQuote(symbol: symbol, name: name, price: price, previousClose: previous,
                          currency: (meta["currency"] as? String) ?? "USD",
                          dayHigh: meta["regularMarketDayHigh"] as? Double, dayLow: meta["regularMarketDayLow"] as? Double,
                          volume: meta["regularMarketVolume"] as? Double,
                          yearHigh: meta["fiftyTwoWeekHigh"] as? Double, yearLow: meta["fiftyTwoWeekLow"] as? Double)
    }

    /// The most recent news headline for a stock, if Yahoo has one.
    static func headline(_ symbol: String) async -> String? {
        guard var comps = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search") else { return nil }
        comps.queryItems = [URLQueryItem(name: "q", value: symbol), URLQueryItem(name: "quotesCount", value: "0"),
                            URLQueryItem(name: "newsCount", value: "1")]
        guard let url = comps.url, let json = await get(url) as? [String: Any],
              let title = (json["news"] as? [[String: Any]])?.first?["title"] as? String else { return nil }
        return title
    }
}

/// Watches the stocks you pick and announces when one moves past your trigger (percent from the previous close).
/// Checks every couple of minutes while BOT is running; with "Speak alerts even in silent mode" on, BOT stays
/// running in the background so the check continues.
@MainActor
final class StockWatcher: ObservableObject {
    @Published private(set) var watches: [StockWatch] = []
    @Published private(set) var quotes: [String: StockQuote] = [:]

    private let reminders: ReminderCenter
    private let fileURL: URL
    private var timer: Timer?
    private var refreshing = false

    init(reminders: ReminderCenter) {
        self.reminders = reminders
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BOT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("stocks.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([StockWatch].self, from: data) { watches = decoded }
        updateSchedule()
    }

    func add(symbol: String, name: String, percent: Double, rising: Bool) {
        watches.removeAll { $0.symbol == symbol }
        watches.append(StockWatch(symbol: symbol, name: name, percent: percent, rising: rising))
        save()
        updateSchedule()
        Task { await refresh() }
    }

    func remove(_ w: StockWatch) {
        watches.removeAll { $0.id == w.id }
        save()
        updateSchedule()
    }

    private func updateSchedule() {
        timer?.invalidate()
        timer = nil
        reminders.keepAliveWanted = !watches.isEmpty
        guard !watches.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Fetches every watched quote and announces any that crossed their trigger today.
    func refresh() async {
        guard !refreshing, !watches.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let today = Self.dayKey()
        for w in watches {
            guard let q = await StockService.quote(w.symbol) else { continue }
            quotes[w.symbol] = q
            guard let idx = watches.firstIndex(where: { $0.id == w.id }), watches[idx].lastAlertDay != today else { continue }
            let change = q.changePercent
            let hit = w.rising ? change >= w.percent : change <= -w.percent
            guard hit else { continue }
            watches[idx].lastAlertDay = today
            save()
            let headline = await StockService.headline(w.symbol)
            announce(q, change: change, headline: headline)
        }
    }

    private func announce(_ q: StockQuote, change: Double, headline: String?) {
        let direction = change >= 0 ? "up" : "down"
        let pct = String(format: "%.1f", abs(change))
        let unit = ["USD": "dollars", "CAD": "Canadian dollars"][q.currency] ?? q.currency
        func money(_ v: Double) -> String { String(format: "%.2f", v) }

        var parts = ["Stock alert. \(q.name) is \(direction) \(pct) percent from yesterday's close, trading at \(money(q.price)) \(unit)."]
        parts.append("That is \(money(abs(q.price - q.previousClose))) \(change >= 0 ? "above" : "below") the previous close of \(money(q.previousClose)).")
        if let hi = q.dayHigh, let lo = q.dayLow { parts.append("Today's range is \(money(lo)) to \(money(hi)).") }
        if let v = q.volume, v > 0 { parts.append("Volume is \(Self.spokenVolume(v)) shares.") }
        if let hi = q.yearHigh, let lo = q.yearLow, hi > lo {
            let spot = (q.price - lo) / (hi - lo) * 100
            parts.append("Over the past year it has ranged from \(money(lo)) to \(money(hi)), so it is at \(Int(spot.rounded())) percent of that range.")
        }
        if let headline { parts.append("Latest headline: \(headline).") }

        reminders.announceNow(key: "stock-\(q.symbol)-\(Self.dayKey())", line: parts.joined(separator: " "),
                              title: "\(q.symbol) \(direction) \(pct)%",
                              body: "\(q.name) is trading at \(money(q.price)) \(q.currency). " + (headline ?? ""))
    }

    private static func spokenVolume(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1f million", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0f thousand", v / 1_000) }
        return String(Int(v))
    }

    private static func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(watches) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
