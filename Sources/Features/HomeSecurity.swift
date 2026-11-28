import Foundation

/// The Home Security dashboard on the mini PC (reached over Tailscale) lets BOT check and control both homes:
/// alarms, locks, lights, plugs, garage doors, thermostats, Blink cameras, Starlink, Wi-Fi and propane.
/// The dashboard does the understanding; BOT sends what was said and speaks the answer, so new commands
/// can be added on the PC without rebuilding BOT. Risky actions (disarm, unlock, open a garage...) come
/// back as a question, and BOT sends the next thing you say along with the `pending` token.
struct HomeReply: Decodable {
    let handled: Bool
    let say: String
    let pending: String?
    let open: String?
}

enum HomeSecurityError: LocalizedError {
    case notSetUp, unauthorized, http(Int), unreachable

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Home Security isn't set up yet. Add the dashboard address and key in Settings."
        case .unauthorized: return "The home dashboard didn't accept BOT's key. Copy the key again from the dashboard's Settings."
        case .http(let code): return "The home dashboard had a problem (error \(code))."
        case .unreachable: return "I can't reach the home dashboard. Check that Tailscale is switched on."
        }
    }
}

@MainActor
final class HomeSecurity: ObservableObject {
    static let keyAccount = "home-security-key"
    private static let addressKey = "homeSecurityAddress"
    private static let namesKey = "homeSecurityNames"

    @Published private(set) var address: String
    @Published private(set) var hasKey: Bool
    /// Follow-up token: the dashboard asked a yes/no or "which home?" question.
    var pending: String?
    /// Device and place words from the dashboard, so "turn on the fireplace" reaches it.
    private var names: Set<String>

    init() {
        address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        hasKey = !(Keychain.get(Self.keyAccount) ?? "").isEmpty
        names = Set(UserDefaults.standard.stringArray(forKey: Self.namesKey) ?? [])
    }

    var isConfigured: Bool { !address.isEmpty && hasKey }

    func save(address raw: String, key: String) {
        var a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty && !a.lowercased().hasPrefix("http") { a = "https://" + a }
        while a.hasSuffix("/") { a.removeLast() }
        address = a
        UserDefaults.standard.set(a, forKey: Self.addressKey)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty {
            Keychain.set(k, for: Self.keyAccount)
            hasKey = true
        }
    }

    func forget() {
        Keychain.set("", for: Self.keyAccount)
        hasKey = false
        address = ""
        pending = nil
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
        UserDefaults.standard.removeObject(forKey: Self.namesKey)
        names = []
    }

    private static let homeWords = try! NSRegularExpression(
        pattern: #"\b(alarm|arm|armed|disarm|disarmed|security|lock|locks|locked|unlock|unlocked|garage|garages|gate|lights?|lamps?|plugs?|outlets?|thermostat|heat|heating|furnace|propane|tanks?|starlink|dish|wi-?fi|eero|internet|cameras?|blink|arlo|doorbell|leaks?|doors?|windows?|viewmount|view mount|hawkins|lake ?house|cottage|smart life|fireplace|fan|house|home|dashboard|turn (on|off|up|down)|switch (on|off))\b"#,
        options: [.caseInsensitive])

    /// Worth asking the dashboard? It answers "not mine" for anything else, so BOT then replies normally.
    func mightBeHome(_ text: String) -> Bool {
        guard isConfigured else { return false }
        if pending != nil { return true }
        let range = NSRange(text.startIndex..., in: text)
        if Self.homeWords.firstMatch(in: text, range: range) != nil { return true }
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains { names.contains($0) }
    }

    private func request(_ path: String) throws -> URLRequest {
        guard isConfigured, let url = URL(string: address + "/" + path), let key = Keychain.get(Self.keyAccount) else {
            throw HomeSecurityError.notSetUp
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("1", forHTTPHeaderField: "X-Dashboard")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            throw HomeSecurityError.unreachable
        }
        let (data, resp) = result
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw HomeSecurityError.unauthorized }
        guard (200..<300).contains(code) else { throw HomeSecurityError.http(code) }
        return data
    }

    func ask(_ text: String) async throws -> HomeReply {
        var req = try request("api/bot/ask")
        req.httpMethod = "POST"
        var body: [String: Any] = ["text": text]
        if let p = pending { body["pending"] = p }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        pending = nil
        let reply = try JSONDecoder().decode(HomeReply.self, from: try await send(req))
        pending = reply.pending
        return reply
    }

    /// For Settings: checks the address and key, and learns the device names.
    func test() async -> String {
        do {
            let data = try await send(try request("api/bot/ping"))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let homes = json["homes"] as? [String] ?? []
            let list = (json["names"] as? [String] ?? []).map { $0.lowercased() }
            names = Set(list)
            UserDefaults.standard.set(list, forKey: Self.namesKey)
            return homes.isEmpty ? "Connected." : "Connected to " + ListFormatter.localizedString(byJoining: homes) + "."
        } catch {
            return error.localizedDescription
        }
    }

    /// The dashboard page for a tab such as "#cameras".
    func pageURL(_ tab: String?) -> URL? {
        URL(string: address + "/" + (tab ?? ""))
    }
}
