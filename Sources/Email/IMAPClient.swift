import Foundation

enum MailError: LocalizedError {
    case connection(String)
    case auth
    case server(String)

    var errorDescription: String? {
        switch self {
        case .connection(let m): return m
        case .auth: return "The mail server rejected the sign-in. Check the email address and app-specific password."
        case .server(let m): return "The mail server said: \(m)"
        }
    }
}

struct RawMessage {
    var uid = 0
    var header = Data()
    var body = Data()
}

/// A small read-only IMAP client over TLS (port 993) built on URLSessionStreamTask. Uses EXAMINE and BODY.PEEK,
/// so reading mail through BOT never marks anything as read.
final class IMAPClient {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private var tagNumber = 0

    enum Item {
        case line(String)
        case literal(Data)
    }

    init(host: String, port: Int = 993) {
        session = URLSession(configuration: .ephemeral)
        task = session.streamTask(withHostName: host, port: port)
        task.startSecureConnection()
        task.resume()
    }

    deinit {
        task.closeRead()
        task.closeWrite()
        session.invalidateAndCancel()
    }

    // MARK: Low level

    private func fill() async throws {
        let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 65_536, timeout: 25)
        if let data, !data.isEmpty {
            buffer.append(data)
        } else if atEOF {
            throw MailError.connection("The mail server closed the connection.")
        }
    }

    private func readLine() async throws -> String {
        let crlf = Data([13, 10])
        while true {
            if let r = buffer.range(of: crlf) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let chunk = Data(buffer.prefix(n))
        buffer.removeFirst(n)
        return chunk
    }

    private static func literalSize(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: open)..<line.index(before: line.endIndex)])
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Sends one command and collects the untagged responses (with literals) up to the tagged reply.
    @discardableResult
    private func command(_ cmd: String) async throws -> [Item] {
        tagNumber += 1
        let tag = "A\(tagNumber)"
        try await task.write(Data("\(tag) \(cmd)\r\n".utf8), timeout: 25)
        var items: [Item] = []
        while true {
            var line = try await readLine()
            while let n = Self.literalSize(line) {
                items.append(.line(line))
                items.append(.literal(try await readBytes(n)))
                line = try await readLine()
            }
            if line.hasPrefix(tag + " ") {
                let status = line.dropFirst(tag.count + 1)
                if status.uppercased().hasPrefix("OK") { return items }
                throw MailError.server(String(status))
            }
            items.append(.line(line))
        }
    }

    // MARK: Commands

    func login(user: String, password: String) async throws {
        _ = try await readLine()   // server greeting
        do {
            try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))")
        } catch MailError.server(_) {
            throw MailError.auth
        }
    }

    func examineInbox() async throws {
        try await command("EXAMINE INBOX")
    }

    func unseenCount() async throws -> Int {
        let items = try await command("STATUS INBOX (UNSEEN)")
        for case .line(let l) in items {
            if let r = l.range(of: #"UNSEEN (\d+)"#, options: .regularExpression) {
                return Int(l[r].dropFirst(7)) ?? 0
            }
        }
        return 0
    }

    /// UIDs matching an IMAP search, ascending ("UNSEEN", "FROM \"dana\"", ...).
    func search(_ criteria: String) async throws -> [Int] {
        let items = try await command("UID SEARCH \(criteria)")
        for case .line(let l) in items where l.hasPrefix("* SEARCH") {
            return l.dropFirst(8).split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    func fetch(uids: [Int], includeBody: Bool) async throws -> [RawMessage] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let headerFields = "BODY.PEEK[HEADER.FIELDS (FROM REPLY-TO SUBJECT DATE MESSAGE-ID REFERENCES CONTENT-TYPE CONTENT-TRANSFER-ENCODING)]"
        let body = includeBody ? " BODY.PEEK[TEXT]<0.6000>" : ""
        let items = try await command("UID FETCH \(set) (UID \(headerFields)\(body))")

        var out: [RawMessage] = []
        var current: RawMessage?
        var lastLine = ""
        for item in items {
            switch item {
            case .line(let l):
                lastLine = l
                if l.range(of: #"^\* \d+ FETCH"#, options: .regularExpression) != nil {
                    if let c = current { out.append(c) }
                    current = RawMessage()
                }
                if current?.uid == 0, let r = l.range(of: #"\bUID (\d+)"#, options: .regularExpression) {
                    current?.uid = Int(l[r].dropFirst(4)) ?? 0
                }
            case .literal(let data):
                if lastLine.contains("HEADER") { current?.header = data } else { current?.body = data }
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    func logout() async {
        _ = try? await command("LOGOUT")
    }
}
