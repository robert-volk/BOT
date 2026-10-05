import Foundation
import NaturalLanguage

enum DocConstants {
    /// Size of Apple's English sentence embeddings.
    static let dim = 512
}

struct DocRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var fileName: String
    var added = Date()
    var chunkCount = 0
    var pageCount = 0
    var status = "indexing"       // "indexing", "ready", or "failed: reason"
    var progress = 0.0
}

struct DocChunk: Codable {
    var docID: UUID
    var docName: String
    var location: String          // "page 3", "sheet Budget", or ""
    var text: String
}

/// Your document library. Files are copied into the app, read and indexed on the phone, and searched with a mix of
/// Apple's on-device embeddings (meaning) and keyword matching (exact terms, names and numbers).
@MainActor
final class DocumentStore: ObservableObject {
    struct Hit: Identifiable {
        let id = UUID()
        let chunk: DocChunk
        let score: Double
    }

    private struct IndexFile: Codable {
        var docs: [DocRecord]
        var chunks: [DocChunk]
    }

    @Published private(set) var docs: [DocRecord] = []
    @Published private(set) var chunks: [DocChunk] = []
    private var vectors: [Float] = []
    private var lowered: [String] = []

    private let dir: URL
    private static let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("BOT/docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    var isEmpty: Bool { chunks.isEmpty }
    var readyCount: Int { docs.filter { $0.status == "ready" }.count }
    var isIndexing: Bool { docs.contains { $0.status == "indexing" } }

    // MARK: Adding and removing

    static let supportedExtensions: Set<String> = ["pdf", "docx", "xlsx", "rtf", "txt", "md", "markdown", "csv",
                                                   "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    /// Files or whole folders (every supported file inside a folder is added).
    func add(urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                for file in Self.supportedFiles(in: url) { importOne(file) }
            } else {
                importOne(url)
            }
        }
    }

    private static func supportedFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let file as URL in walker where supportedExtensions.contains(file.pathExtension.lowercased()) {
            files.append(file)
        }
        return files
    }

    private func importOne(_ url: URL) {
        // Adding the same file again replaces the earlier copy.
        if let existing = docs.first(where: { $0.name == url.lastPathComponent }) { remove(existing) }
        let fileName = UUID().uuidString + "-" + url.lastPathComponent
        let dest = dir.appendingPathComponent(fileName)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return }

        let record = DocRecord(name: url.lastPathComponent, fileName: fileName)
        docs.append(record)
        saveIndex()
        let id = record.id
        let name = record.name
        Task.detached(priority: .utility) { [weak self] in
            let result = await DocumentIndexer.index(id: id, url: dest, name: name) { p in
                Task { @MainActor in self?.updateProgress(id, p) }
            }
            await self?.finish(id: id, result: result)
        }
    }

    func remove(_ doc: DocRecord) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(doc.fileName))
        var newChunks: [DocChunk] = []
        var newVectors: [Float] = []
        let dim = DocConstants.dim
        for (i, c) in chunks.enumerated() where c.docID != doc.id {
            newChunks.append(c)
            newVectors += vectors[(i * dim)..<((i + 1) * dim)]
        }
        chunks = newChunks
        vectors = newVectors
        lowered = newChunks.map { $0.text.lowercased() }
        docs.removeAll { $0.id == doc.id }
        saveIndex()
    }

    private func updateProgress(_ id: UUID, _ p: Double) {
        guard let i = docs.firstIndex(where: { $0.id == id }), docs[i].status == "indexing" else { return }
        docs[i].progress = p
    }

    private func finish(id: UUID, result: DocumentIndexer.Result) {
        guard let i = docs.firstIndex(where: { $0.id == id }) else { return }
        if let error = result.error {
            docs[i].status = "failed: " + error
            docs[i].progress = 0
            saveIndex()
            return
        }
        chunks += result.chunks
        lowered += result.chunks.map { $0.text.lowercased() }
        vectors += result.vectors
        docs[i].status = "ready"
        docs[i].chunkCount = result.chunks.count
        docs[i].pageCount = result.pages
        docs[i].progress = 1
        saveIndex()
    }

    // MARK: Search

    private static let stop: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "which", "who", "whom", "does", "did", "how", "when", "where",
        "that", "this", "these", "those", "with", "from", "have", "has", "had", "about", "into", "than", "then", "there",
        "their", "them", "they", "you", "your", "can", "could", "should", "would", "will", "say", "says", "tell", "give",
        "any", "all", "not", "but", "out", "per", "its", "our", "his", "her", "document", "documents", "file", "files",
        "according", "mention", "mentions", "please",
    ]

    static func terms(_ query: String) -> [String] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) }
            .map(stem)
        return Array(Set(words))
    }

    private static func stem(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    /// Best passages for a question, strongest first.
    func search(_ query: String, limit: Int = 5) -> [Hit] {
        let n = chunks.count
        guard n > 0, lowered.count == n, vectors.count == n * DocConstants.dim else { return [] }

        // Keyword coverage: the share of the question's (rarity-weighted) terms that a passage contains.
        let terms = Self.terms(query)
        var coverage = [Double](repeating: 0, count: n)
        if !terms.isEmpty {
            var weights: [Double] = []
            var present: [[Bool]] = []
            for term in terms {
                var flags = [Bool](repeating: false, count: n)
                var df = 0
                for i in 0..<n where lowered[i].contains(term) {
                    flags[i] = true
                    df += 1
                }
                weights.append(df == 0 ? 0 : log(1 + Double(n) / Double(1 + df)))
                present.append(flags)
            }
            let total = max(weights.reduce(0, +), 0.0001)
            for i in 0..<n {
                var s = 0.0
                for (t, w) in weights.enumerated() where present[t][i] { s += w }
                coverage[i] = s / total
            }
        }

        // Meaning: cosine similarity of Apple's sentence embeddings.
        var semantic = [Double](repeating: 0, count: n)
        var hasSemantic = false
        let dim = DocConstants.dim
        if let embedder = Self.embedding, embedder.dimension == dim, let raw = embedder.vector(for: query) {
            var q = raw.map { Float($0) }
            let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
            if norm > 0 {
                q = q.map { $0 / norm }
                hasSemantic = true
                vectors.withUnsafeBufferPointer { buf in
                    for i in 0..<n {
                        var dot: Float = 0
                        let base = i * dim
                        for k in 0..<dim { dot += q[k] * buf[base + k] }
                        semantic[i] = Double(dot)
                    }
                }
            }
        }

        var scored: [(Int, Double)] = []
        scored.reserveCapacity(n)
        for i in 0..<n {
            let s = hasSemantic ? min(1, max(0, (semantic[i] - 0.3) / 0.5)) : 0
            let combined = hasSemantic ? 0.5 * s + 0.5 * coverage[i] : coverage[i]
            scored.append((i, combined))
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).filter { $0.1 > 0 }.map { Hit(chunk: chunks[$0.0], score: $0.1) }
    }

    // MARK: Persistence

    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private var vectorsURL: URL { dir.appendingPathComponent("vectors.bin") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data) else { return }
        docs = file.docs
        chunks = file.chunks
        lowered = chunks.map { $0.text.lowercased() }
        let expected = chunks.count * DocConstants.dim
        if let vdata = try? Data(contentsOf: vectorsURL), vdata.count == expected * MemoryLayout<Float>.size {
            vectors = vdata.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else {
            vectors = [Float](repeating: 0, count: expected)   // damaged: keyword search still works
        }
        // Anything that was still indexing when the app closed did not finish.
        for i in docs.indices where docs[i].status == "indexing" {
            docs[i].status = "failed: interrupted, remove it and add it again"
        }
    }

    private func saveIndex() {
        let file = IndexFile(docs: docs, chunks: chunks)
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: indexURL, options: .atomic) }
        let vdata = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try? vdata.write(to: vectorsURL, options: .atomic)
    }
}

// MARK: - Voice commands

enum DocsIntent {
    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let library = #"(?:documents?|docs|files|library|repository|knowledge ?base)"#
    private static let docNoun = #"(?:policy|policies|handbook|manual|document|contract|agreement|report|guide|procedure|spec|specification|pdf|spreadsheet|memo)"#

    /// "search my documents for...", "according to my documents...", "what does the travel policy say about..."
    static func isExplicit(_ text: String) -> Bool {
        matches(#"\b(?:search|look(?:\s+up)?|find|check|query|ask)\b.{0,25}\b(?:my |the |our )?"# + library + #"\b"#, text)
            || matches(#"\b(?:according to|based on|in|from|per|using)\s+(?:my|the|our)\s+"# + library + #"\b"#, text)
            || matches(#"\bwhat (?:does|do)\b.{0,60}\b"# + docNoun + #"\b.{0,40}\b(?:say|says|state|states|mention|mentions|specify|specifies)\b"#, text)
    }

    /// The question without the "search my documents for" part.
    static func query(from text: String) -> String {
        var t = text
        let lead = #"^(?:please )?(?:search|look(?: up)?|find|check|query|ask)\s+(?:in |through )?(?:my |the |our )?"# + library + #"\s*(?:for|about|on|and tell me)?\s*"#
        t = t.replacingOccurrences(of: lead, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\b(?:according to|based on|in|from|per|using)\s+(?:my|the|our)\s+"# + library + #"\b,?"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        return t.isEmpty ? text : t
    }

    static func isListRequest(_ text: String) -> Bool {
        matches(#"\b(?:what|which|list|how many)\b.{0,20}\b"# + library + #"\b.{0,25}\b(?:do i have|have i added|are there|are in|in my|i have)\b"#, text)
    }
}
