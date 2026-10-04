import Foundation

/// Turns raw email headers and bodies into readable text: RFC 2047 encoded words, quoted-printable,
/// base64, multipart/alternative, HTML stripping.
enum MailParsing {
    // MARK: Headers

    static func parseHeaders(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var result: [String: String] = [:]
        var currentKey: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.first == " " || line.first == "\t" {
                if let k = currentKey { result[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                currentKey = key
                result[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    static func param(_ header: String, _ name: String) -> String? {
        let pattern = name + #"\s*=\s*"?([^";\s]+)"?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let r = Range(m.range(at: 1), in: header) else { return nil }
        return String(header[r])
    }

    /// "=?UTF-8?B?...?=" and "=?utf-8?Q?...?=" words in From / Subject.
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let joined = s.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return s }
        let ns = joined as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1))
            let kind = ns.substring(with: m.range(at: 2)).lowercased()
            let payload = ns.substring(with: m.range(at: 3))
            var bytes = Data()
            if kind == "b" {
                bytes = Data(base64Encoded: payload) ?? Data()
            } else {
                bytes = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            result += String(data: bytes, encoding: encoding(charset)) ?? ""
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static func encoding(_ name: String) -> String.Encoding {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf == kCFStringEncodingInvalidId { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: Encodings

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 {   // "="
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h * 16 + l)
                    i += 3
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return Data(out)
    }

    // MARK: Bodies

    /// Readable text from a message body (possibly cut short by a partial fetch).
    static func readableText(headers: [String: String], body: Data) -> String {
        let text = bodyText(headers: headers, body: body)
        return tidy(text)
    }

    private static func bodyText(headers: [String: String], body: Data) -> String {
        let contentType = headers["content-type"] ?? "text/plain"
        let lower = contentType.lowercased()
        if lower.hasPrefix("multipart/"), let boundary = param(contentType, "boundary") {
            let raw = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            var plain: String?
            var html: String?
            for part in raw.components(separatedBy: "--" + boundary).dropFirst() {
                guard let split = part.range(of: "\n\n") else { continue }
                let partHeaders = parseHeaders(Data(part[..<split.lowerBound].utf8))
                let partBody = Data(part[split.upperBound...].utf8)
                let t = (partHeaders["content-type"] ?? "text/plain").lowercased()
                if t.hasPrefix("multipart/") {
                    let nested = bodyText(headers: partHeaders, body: partBody)
                    if plain == nil, !nested.isEmpty { plain = nested }
                } else if t.hasPrefix("text/plain"), plain == nil {
                    plain = decodePart(headers: partHeaders, body: partBody)
                } else if t.hasPrefix("text/html"), html == nil {
                    html = stripHTML(decodePart(headers: partHeaders, body: partBody))
                }
            }
            return plain ?? html ?? ""
        }
        let decoded = decodePart(headers: headers, body: body)
        return lower.hasPrefix("text/html") ? stripHTML(decoded) : decoded
    }

    private static func decodePart(headers: [String: String], body: Data) -> String {
        let transfer = (headers["content-transfer-encoding"] ?? "").lowercased()
        var data = body
        if transfer.contains("base64") {
            var cleaned = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            cleaned = String(cleaned.prefix(cleaned.count - cleaned.count % 4))
            data = Data(base64Encoded: cleaned) ?? Data()
        } else if transfer.contains("quoted-printable") {
            data = decodeQuotedPrintable(body)
        }
        let charset = headers["content-type"].flatMap { param($0, "charset") } ?? "utf-8"
        return String(data: data, encoding: encoding(charset))
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stripHTML(_ html: String) -> String {
        var t = html
        for tag in ["style", "script", "head"] {
            t = t.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: "<br[^>]*>|</p>|</div>|</tr>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&rsquo;": "'", "&ldquo;": "\"", "&rdquo;": "\""]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }

    /// Drops quoted replies, signatures and blank runs; keeps the first few hundred characters.
    private static func tidy(_ text: String) -> String {
        var kept: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { continue }
            if line.range(of: #"^On .{5,120} wrote:$"#, options: .regularExpression) != nil { break }
            if line.hasPrefix("-----Original Message") || line == "--" || line == "-- " { break }
            if line.range(of: #"^(?:From|Sent|To|Subject):\s"#, options: .regularExpression) != nil, kept.count > 2 { break }
            kept.append(line)
        }
        let joined = kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(joined.prefix(900))
    }

    // MARK: Addresses

    /// "Dana Smith <dana@x.com>" → ("Dana Smith", "dana@x.com")
    static func parseAddress(_ raw: String) -> (name: String, address: String) {
        let decoded = decodeWords(raw)
        if let re = try? NSRegularExpression(pattern: #"^\s*"?([^"<]*?)"?\s*<([^>]+)>"#),
           let m = re.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
           let n = Range(m.range(at: 1), in: decoded), let a = Range(m.range(at: 2), in: decoded) {
            let name = String(decoded[n]).trimmingCharacters(in: .whitespaces)
            let address = String(decoded[a]).trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? address.split(separator: "@").first.map(String.init) ?? address : name, address)
        }
        let address = decoded.trimmingCharacters(in: CharacterSet(charactersIn: " <>\""))
        return (address.split(separator: "@").first.map(String.init) ?? address, address)
    }
}
