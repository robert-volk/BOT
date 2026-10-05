import Foundation
import PDFKit
import NaturalLanguage
import UIKit
import Compression

/// Reads a file into passages and their embeddings. Runs off the main thread.
enum DocumentIndexer {
    struct Result {
        var chunks: [DocChunk] = []
        var vectors: [Float] = []
        var pages = 0
        var error: String?
    }

    typealias Segment = (location: String, text: String)

    static func index(id: UUID, url: URL, name: String, progress: @escaping @Sendable (Double) -> Void) async -> Result {
        progress(0.03)
        let ext = url.pathExtension.lowercased()
        var segments: [Segment] = []
        var pages = 0

        switch ext {
        case "pdf":
            (segments, pages) = await pdfSegments(url, progress: progress)
        case "docx":
            segments = docxSegments(url)
        case "xlsx":
            segments = xlsxSegments(url)
        case "rtf":
            let text = (try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                documentAttributes: nil))?.string ?? ""
            segments = [("", text)]
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff":
            if let data = try? Data(contentsOf: url) { segments = [("", await TextReader.read(data))] }
            pages = 1
        default:   // txt, md, csv, json, log...
            if let data = try? Data(contentsOf: url) {
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                segments = [("", text)]
            }
        }
        segments = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !segments.isEmpty else {
            return Result(error: ext == "doc" || ext == "xls" ? "old Word/Excel format, save it as .docx or .xlsx" : "no readable text found")
        }
        progress(0.5)

        let pieces = chunk(segments).prefix(8000)
        let dim = DocConstants.dim
        let embedder = NLEmbedding.sentenceEmbedding(for: .english)
        var chunks: [DocChunk] = []
        var vectors: [Float] = []
        vectors.reserveCapacity(pieces.count * dim)
        for (i, piece) in pieces.enumerated() {
            chunks.append(DocChunk(docID: id, docName: name, location: piece.location, text: piece.text))
            if let e = embedder, e.dimension == dim, let v = e.vector(for: String(piece.text.prefix(1500))) {
                var f = v.map { Float($0) }
                let norm = sqrt(f.reduce(0) { $0 + $1 * $1 })
                if norm > 0 { f = f.map { $0 / norm } }
                vectors += f
            } else {
                vectors += [Float](repeating: 0, count: dim)
            }
            if i % 25 == 0 { progress(0.5 + 0.5 * Double(i) / Double(max(pieces.count, 1))) }
        }
        return Result(chunks: chunks, vectors: vectors, pages: pages == 0 ? segments.count : pages, error: nil)
    }

    // MARK: PDF (with on-device text recognition for scanned pages)

    private static func pdfSegments(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async -> ([Segment], Int) {
        guard let pdf = PDFDocument(url: url) else { return ([], 0) }
        var out: [Segment] = []
        let count = max(pdf.pageCount, 1)
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < 25 {
                let image = page.thumbnail(of: CGSize(width: 1500, height: 2000), for: .mediaBox)
                if let jpeg = image.jpegData(compressionQuality: 0.85) {
                    text = (await TextReader.read(jpeg)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !text.isEmpty { out.append(("page \(i + 1)", text)) }
            progress(0.05 + 0.4 * Double(i + 1) / Double(count))
        }
        return (out, pdf.pageCount)
    }

    // MARK: Word (.docx)

    private static func docxSegments(_ url: URL) -> [Segment] {
        guard let zip = ZipReader(url: url), let data = zip.read("word/document.xml") else { return [] }
        var xml = String(decoding: data, as: UTF8.self)
        xml = xml.replacingOccurrences(of: "<w:instrText[^>]*>.*?</w:instrText>", with: "", options: .regularExpression)
        xml = xml.replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "</w:tc>", with: " | ")
            .replacingOccurrences(of: "<w:tab/>", with: "\t")
            .replacingOccurrences(of: "<w:br/>", with: "\n")
        xml = xml.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return [("", XML.decode(xml))]
    }

    // MARK: Excel (.xlsx)

    private static func xlsxSegments(_ url: URL) -> [Segment] {
        guard let zip = ZipReader(url: url) else { return [] }

        var shared: [String] = []
        if let d = zip.read("xl/sharedStrings.xml") {
            let xml = String(decoding: d, as: UTF8.self)
            for item in XML.matches(#"<si>(.*?)</si>"#, in: xml) {
                let pieces = XML.matches(#"<t[^>]*>(.*?)</t>"#, in: item)
                shared.append(XML.decode(pieces.joined()))
            }
        }
        var names: [String] = []
        if let d = zip.read("xl/workbook.xml") {
            names = XML.matches(#"<sheet [^>]*name="([^"]*)""#, in: String(decoding: d, as: UTF8.self)).map { XML.decode($0) }
        }
        let sheetPaths = zip.names
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { lhs, rhs in
                func number(_ s: String) -> Int { Int(s.filter { $0.isNumber }) ?? 0 }
                return number(lhs) < number(rhs)
            }

        var out: [Segment] = []
        for (index, path) in sheetPaths.enumerated() {
            guard let d = zip.read(path) else { continue }
            let xml = String(decoding: d, as: UTF8.self)
            var header: [String: String] = [:]
            var lines: [String] = []
            for row in XML.matches(#"<row[^>]*>(.*?)</row>"#, in: xml).prefix(6000) {
                var cells: [(col: String, value: String)] = []
                guard let re = try? NSRegularExpression(pattern: #"<c r="([A-Z]+)(\d+)"([^>]*?)(?:/>|>(.*?)</c>)"#, options: [.dotMatchesLineSeparators]) else { continue }
                let ns = row as NSString
                var rowNumber = 0
                for m in re.matches(in: row, range: NSRange(location: 0, length: ns.length)) {
                    let col = ns.substring(with: m.range(at: 1))
                    rowNumber = Int(ns.substring(with: m.range(at: 2))) ?? rowNumber
                    let attrs = ns.substring(with: m.range(at: 3))
                    let inner = m.range(at: 4).location == NSNotFound ? "" : ns.substring(with: m.range(at: 4))
                    var value = XML.matches(#"<v>(.*?)</v>"#, in: inner).first ?? ""
                    if attrs.contains(#"t="s""#), let i = Int(value), i < shared.count { value = shared[i] }
                    else if attrs.contains(#"t="inlineStr""#) { value = XML.decode(XML.matches(#"<t[^>]*>(.*?)</t>"#, in: inner).joined()) }
                    else { value = XML.decode(value) }
                    if !value.trimmingCharacters(in: .whitespaces).isEmpty { cells.append((col, value)) }
                }
                guard !cells.isEmpty else { continue }
                if header.isEmpty {
                    for c in cells { header[c.col] = c.value }
                    lines.append("Columns: " + cells.map { $0.value }.joined(separator: ", "))
                } else {
                    let parts = cells.map { (header[$0.col] ?? $0.col) + ": " + $0.value }
                    lines.append("Row \(rowNumber) | " + parts.joined(separator: " | "))
                }
            }
            if !lines.isEmpty {
                let sheetName = index < names.count ? names[index] : "\(index + 1)"
                out.append(("sheet \(sheetName)", lines.joined(separator: "\n")))
            }
        }
        return out
    }

    // MARK: Chunking

    static func chunk(_ segments: [Segment]) -> [(location: String, text: String)] {
        var out: [(location: String, text: String)] = []
        for seg in segments {
            var current = ""
            func flush() {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 20 { out.append((seg.location, t)) }
                current = ""
            }
            for rawPara in seg.text.components(separatedBy: "\n") {
                let para = rawPara.trimmingCharacters(in: .whitespaces)
                if para.isEmpty { continue }
                if para.count > 1200 {
                    flush()
                    for piece in splitSentences(para, size: 900) {
                        current = piece
                        flush()
                    }
                    continue
                }
                if current.count + para.count > 950 { flush() }
                current += (current.isEmpty ? "" : "\n") + para
            }
            flush()
        }
        return out
    }

    private static func splitSentences(_ text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for sentence in text.components(separatedBy: ". ") {
            if current.count + sentence.count > size, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += sentence + ". "
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

// MARK: - XML helpers

enum XML {
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Minimal ZIP reader (for .docx and .xlsx), using Apple's Compression framework

struct ZipReader {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]
    var names: [String] { Array(entries.keys) }

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 22 else { return nil }
        data = d

        func u16(_ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24) }

        // End of central directory record (signature 50 4B 05 06), searching back from the end.
        var eocd = -1
        var i = d.count - 22
        let stop = max(0, d.count - 66_000)
        while i >= stop {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var pos = u32(eocd + 16)

        var found: [String: Entry] = [:]
        for _ in 0..<count {
            guard pos + 46 <= d.count, u32(pos) == 0x02014B50 else { break }
            let method = UInt16(u16(pos + 10))
            let compressed = u32(pos + 20)
            let uncompressed = u32(pos + 24)
            let nameLength = u16(pos + 28)
            let extraLength = u16(pos + 30)
            let commentLength = u16(pos + 32)
            let offset = u32(pos + 42)
            guard pos + 46 + nameLength <= d.count else { break }
            let name = String(decoding: d[(pos + 46)..<(pos + 46 + nameLength)], as: UTF8.self)
            found[name] = Entry(method: method, compressedSize: compressed, uncompressedSize: uncompressed, localOffset: offset)
            pos += 46 + nameLength + extraLength + commentLength
        }
        entries = found
    }

    func read(_ name: String) -> Data? {
        guard let e = entries[name], e.uncompressedSize < 200_000_000 else { return nil }
        let o = e.localOffset
        guard o + 30 <= data.count, data[o] == 0x50, data[o + 1] == 0x4B, data[o + 2] == 0x03, data[o + 3] == 0x04 else { return nil }
        let nameLength = Int(data[o + 26]) | (Int(data[o + 27]) << 8)
        let extraLength = Int(data[o + 28]) | (Int(data[o + 29]) << 8)
        let start = o + 30 + nameLength + extraLength
        guard start + e.compressedSize <= data.count else { return nil }
        let payload = data.subdata(in: start..<(start + e.compressedSize))

        if e.method == 0 { return payload }
        guard e.method == 8 else { return nil }
        if e.uncompressedSize == 0 { return Data() }
        var output = Data(count: e.uncompressedSize)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            payload.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, e.uncompressedSize, s, e.compressedSize, nil, COMPRESSION_ZLIB)
            }
        }
        return written == e.uncompressedSize ? output : nil
    }
}
