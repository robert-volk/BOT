import Foundation

/// Builds a plain-text email (UTF-8, base64 body) ready for SMTP.
enum MailComposer {
    static func build(fromAddress: String, to: String, subject: String, body: String,
                      inReplyTo: String?, references: String?) -> Data {
        let domain = fromAddress.split(separator: "@").last.map(String.init) ?? "botapp.local"
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var headers: [String] = [
            "From: \(fromAddress)",
            "To: \(to)",
            "Subject: \(encodeHeader(subject))",
            "Date: \(date.string(from: Date()))",
            "Message-ID: <\(UUID().uuidString)@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
        ]
        if let inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            let refs = [references ?? "", inReplyTo].filter { !$0.isEmpty }.joined(separator: " ")
            headers.append("References: \(refs)")
        }
        let encodedBody = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody + "\r\n"
        return Data(message.utf8)
    }

    /// RFC 2047 for subjects containing non-ASCII characters.
    private static func encodeHeader(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
    }
}

/// A small SMTP sender (submission over STARTTLS on 587, or implicit TLS on 465), built on URLSessionStreamTask.
final class SMTPClient {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private let startTLS: Bool

    init(host: String, port: Int) {
        startTLS = port != 465
        session = URLSession(configuration: .ephemeral)
        task = session.streamTask(withHostName: host, port: port)
        if !startTLS { task.startSecureConnection() }
        task.resume()
    }

    deinit {
        task.closeRead()
        task.closeWrite()
        session.invalidateAndCancel()
    }

    private func fill() async throws {
        let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 16_384, timeout: 25)
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

    /// Reads a (possibly multi-line) reply and returns its code.
    private func readReply() async throws -> (code: Int, text: String) {
        var text = ""
        while true {
            let line = try await readLine()
            text += line + "\n"
            guard line.count >= 4 else { continue }
            let code = Int(line.prefix(3)) ?? 0
            if line[line.index(line.startIndex, offsetBy: 3)] == " " { return (code, text) }
        }
    }

    @discardableResult
    private func send(_ line: String, expect: [Int]) async throws -> String {
        try await task.write(Data((line + "\r\n").utf8), timeout: 25)
        let reply = try await readReply()
        guard expect.contains(reply.code) else {
            if reply.code == 535 || reply.code == 534 { throw MailError.auth }
            throw MailError.server(reply.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return reply.text
    }

    func deliver(from address: String, user: String, password: String, to recipient: String, message: Data) async throws {
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw MailError.server(greeting.text) }
        try await send("EHLO botapp.local", expect: [250])
        if startTLS {
            try await send("STARTTLS", expect: [220])
            task.startSecureConnection()
            try await send("EHLO botapp.local", expect: [250])
        }
        let credentials = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
        try await send("AUTH PLAIN \(credentials)", expect: [235])
        try await send("MAIL FROM:<\(address)>", expect: [250])
        try await send("RCPT TO:<\(recipient)>", expect: [250, 251])
        try await send("DATA", expect: [354])
        try await task.write(message + Data("\r\n.\r\n".utf8), timeout: 40)
        let done = try await readReply()
        guard done.code == 250 else { throw MailError.server(done.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        _ = try? await send("QUIT", expect: [221])
    }
}
