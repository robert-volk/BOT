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
    // Set for files that came from a synced folder or photo album.
    var sourceID: UUID?
    var path: String?
    var signature: String?
}

struct DocChunk: Codable {
    var docID: UUID
    var docName: String
    var location: String          // "page 3", "sheet Budget", or ""
    var text: String
    var assetID: String? = nil    // photo passages only
    var date: Date? = nil         // photo passages only
}

/// A folder (iCloud Drive, Google Drive, any Files location) or a set of photo albums that BOT keeps in sync.
struct SourceRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: String              // "folder" or "photos"
    var label: String
    var bookmark: Data?
    var albumIDs: [String]?
    var recordID: UUID?           // photos: the library entry that holds the photo passages
    var status = "waiting"
    var lastScan: Date?
    var fileCount = 0
    var note: String?
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

    enum SearchScope { case documents, photos, all }

    private struct IndexFile: Codable {
        var docs: [DocRecord]
        var chunks: [DocChunk]
        var sources: [SourceRecord]?
    }

    @Published private(set) var docs: [DocRecord] = []
    @Published private(set) var chunks: [DocChunk] = []
    @Published private(set) var sources: [SourceRecord] = []
    private var lastRescan = Date.distantPast
    private var scanning = Set<UUID>()
    private var unsavedPhotoChunks = 0
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
    var hasPhotoChunks: Bool { chunks.contains { $0.assetID != nil } }

    // MARK: Adding and removing

    nonisolated static let supportedExtensions: Set<String> = ["pdf", "docx", "xlsx", "rtf", "txt", "md", "markdown", "csv",
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
        if !doc.fileName.isEmpty { try? FileManager.default.removeItem(at: dir.appendingPathComponent(doc.fileName)) }
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
    func search(_ query: String, limit: Int = 5, scope: SearchScope = .documents, dateWindow: ClosedRange<Date>? = nil) -> [Hit] {
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
            let isPhoto = chunks[i].assetID != nil
            if scope == .documents && isPhoto { continue }
            if scope == .photos && !isPhoto { continue }
            if let window = dateWindow {
                guard let d = chunks[i].date, window.contains(d) else { continue }
            }
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
        sources = file.sources ?? []
        for i in sources.indices where sources[i].status != "ready" && !sources[i].status.hasPrefix("failed") {
            sources[i].status = "waiting"   // a scan was interrupted; the next check picks it up
        }
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
        let file = IndexFile(docs: docs, chunks: chunks, sources: sources)
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


// MARK: - Synced folders (iCloud Drive, Google Drive, any Files location) and photo albums

struct SourceFile: Sendable {
    var url: URL
    var name: String
    var path: String
    var signature: String
}

extension DocumentStore {
    // MARK: Adding and removing

    /// A folder picked in the Files app. iCloud Drive folders and the Google Drive app's folders both work.
    func addFolder(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let path = url.path.lowercased()
        let provider = path.contains("com~apple~clouddocs") ? "iCloud Drive" : (path.contains("google") ? "Google Drive" : "Folder")
        var source = SourceRecord(kind: "folder", label: provider + ": " + url.lastPathComponent)
        source.bookmark = bookmark
        sources.append(source)
        saveIndex()
        rescan(source.id)
    }

    func addPhotos(albums: [(id: String, name: String)]) {
        var source = SourceRecord(kind: "photos", label: "Photos: " + albums.map { $0.name }.joined(separator: ", "))
        source.albumIDs = albums.map { $0.id }
        sources.append(source)
        saveIndex()
        rescan(source.id)
    }

    func removeSource(_ source: SourceRecord) {
        for d in docs where d.sourceID == source.id { remove(d) }
        sources.removeAll { $0.id == source.id }
        saveIndex()
    }

    // MARK: Checking for changes

    /// Called when the app opens. Checks every source at most every 10 minutes (or right away when forced).
    func rescanAll(force: Bool = false) {
        guard !sources.isEmpty, force || Date().timeIntervalSince(lastRescan) > 600 else { return }
        lastRescan = Date()
        for s in sources { rescan(s.id) }
    }

    func rescan(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }), !scanning.contains(id) else { return }
        scanning.insert(id)
        setSourceStatus(id, "checking")
        if source.kind == "photos" { scanPhotos(source) } else { scanFolder(source) }
    }

    private func setSourceStatus(_ id: UUID, _ status: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].status = status
    }

    private func finishScan(_ id: UUID, status: String, count: Int, note: String?) {
        scanning.remove(id)
        if let i = sources.firstIndex(where: { $0.id == id }) {
            sources[i].status = status
            sources[i].lastScan = Date()
            sources[i].fileCount = count
            sources[i].note = note
        }
        saveIndex()
    }

    // MARK: Folders

    private func scanFolder(_ source: SourceRecord) {
        let id = source.id
        guard let bookmark = source.bookmark else {
            finishScan(id, status: "failed: folder missing", count: 0, note: nil)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                await self?.finishScan(id, status: "failed: can't open the folder anymore, remove it and add it again", count: 0, note: nil)
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let listing = DocumentStore.listFiles(in: url)
            let todo = await self?.applyListing(id, listing.files) ?? []
            for (n, file) in todo.enumerated() {
                await self?.setSourceStatus(id, "reading file \(n + 1) of \(todo.count)")
                guard let temp = DocumentStore.coordinatedCopy(file.url) else { continue }   // downloads cloud-only files
                if let recordID = await self?.beginRecord(sourceID: id, file: file) {
                    let result = await DocumentIndexer.index(id: recordID, url: temp, name: file.name) { p in
                        Task { @MainActor in self?.updateProgress(recordID, p) }
                    }
                    await self?.finish(id: recordID, result: result)
                }
                try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
            }
            let note = listing.skipped > 0 ? "\(listing.skipped) Google Docs/Sheets skipped: export them as .docx/.xlsx or PDF" : nil
            await self?.finishScan(id, status: "ready", count: listing.files.count, note: note)
        }
    }

    /// Files in the folder (including iCloud placeholders for files not yet downloaded).
    nonisolated static func listFiles(in root: URL) -> (files: [SourceFile], skipped: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsPackageDescendants]) else { return ([], 0) }
        var files: [SourceFile] = []
        var skipped = 0
        let rootPath = root.standardizedFileURL.path
        for case let fileURL as URL in walker {
            var name = fileURL.lastPathComponent
            var target = fileURL
            if name.hasPrefix("."), name.hasSuffix(".icloud") {   // a file that's only in iCloud so far
                name = String(name.dropFirst().dropLast(7))
                target = fileURL.deletingLastPathComponent().appendingPathComponent(name)
            } else if name.hasPrefix(".") {
                continue
            }
            let ext = (name as NSString).pathExtension.lowercased()
            if ["gdoc", "gsheet", "gslides"].contains(ext) { skipped += 1; continue }
            guard supportedExtensions.contains(ext) else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true else { continue }
            let size = values?.fileSize ?? 0
            let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            var path = target.standardizedFileURL.path
            if path.hasPrefix(rootPath) { path = String(path.dropFirst(rootPath.count)) }
            files.append(SourceFile(url: target, name: name, path: path, signature: "\(size)-\(modified)"))
        }
        return (files, skipped)
    }

    /// Copies a file to a temporary location through the file coordinator, which makes iCloud Drive and Google Drive
    /// download it first if needed.
    nonisolated static func coordinatedCopy(_ url: URL) -> URL? {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: url.path) { break }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        var error: NSError?
        var result: URL?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: readURL, to: dest)) != nil { result = dest }
        }
        return result
    }

    /// Removes library entries for files that left the folder; returns the files that are new or changed.
    private func applyListing(_ sourceID: UUID, _ files: [SourceFile]) -> [SourceFile] {
        let existing = docs.filter { $0.sourceID == sourceID }
        let present = Set(files.map { $0.path })
        for doc in existing where !(doc.path.map { present.contains($0) } ?? false) { remove(doc) }
        return files.filter { f in
            guard let d = existing.first(where: { $0.path == f.path }) else { return true }
            return d.signature != f.signature || d.status != "ready"
        }
    }

    private func beginRecord(sourceID: UUID, file: SourceFile) -> UUID {
        if let old = docs.first(where: { $0.sourceID == sourceID && $0.path == file.path }) { remove(old) }
        var record = DocRecord(name: file.name, fileName: "")
        record.sourceID = sourceID
        record.path = file.path
        record.signature = file.signature
        docs.append(record)
        saveIndex()
        return record.id
    }

    // MARK: Photos

    private func scanPhotos(_ source: SourceRecord) {
        let id = source.id
        let albumIDs = source.albumIDs ?? []
        let recordID = ensurePhotoRecord(for: source)
        let known = Set(chunks.filter { $0.docID == recordID }.compactMap { $0.assetID })
        Task.detached(priority: .utility) { [weak self] in
            guard await PhotoIndexer.authorize() else {
                await self?.finishScan(id, status: "failed: Photos access is off, turn it on in iPhone Settings, Privacy and Security, Photos", count: 0, note: nil)
                return
            }
            let limit = 300
            let assetIDs = PhotoIndexer.newAssetIDs(inAlbums: albumIDs, excluding: known, limit: limit)
            let embedder = NLEmbedding.sentenceEmbedding(for: .english)
            for (n, assetID) in assetIDs.enumerated() {
                if let item = await PhotoIndexer.describe(assetID: assetID, embedder: embedder) {
                    await self?.appendPhoto(recordID, item)
                }
                if n % 5 == 0 { await self?.setSourceStatus(id, "reading photo \(n + 1) of \(assetIDs.count)") }
            }
            await self?.finishPhotoScan(id, recordID, more: assetIDs.count >= limit)
        }
    }

    private func ensurePhotoRecord(for source: SourceRecord) -> UUID {
        if let rid = source.recordID, docs.contains(where: { $0.id == rid }) { return rid }
        var record = DocRecord(name: source.label, fileName: "")
        record.sourceID = source.id
        record.status = "ready"
        docs.append(record)
        if let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i].recordID = record.id }
        saveIndex()
        return record.id
    }

    private func appendPhoto(_ recordID: UUID, _ item: PhotoIndexer.Item) {
        guard let doc = docs.first(where: { $0.id == recordID }) else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let when = item.date.map { formatter.string(from: $0) } ?? "undated"
        chunks.append(DocChunk(docID: recordID, docName: doc.name, location: "photo · " + when, text: item.text,
                               assetID: item.assetID, date: item.date))
        lowered.append(item.text.lowercased())
        vectors += item.vector
        unsavedPhotoChunks += 1
        if unsavedPhotoChunks >= 20 {
            unsavedPhotoChunks = 0
            saveIndex()
        }
    }

    private func finishPhotoScan(_ id: UUID, _ recordID: UUID, more: Bool) {
        let count = chunks.filter { $0.docID == recordID }.count
        if let i = docs.firstIndex(where: { $0.id == recordID }) {
            docs[i].chunkCount = count
            docs[i].pageCount = count
            docs[i].status = "ready"
            docs[i].progress = 1
        }
        unsavedPhotoChunks = 0
        finishScan(id, status: "ready", count: count, note: more ? "Check again to read more of your older photos" : nil)
    }

    /// Photo passages (newest first), optionally within a date window. For "show me photos from last week".
    func recentPhotoChunks(in window: ClosedRange<Date>?, limit: Int) -> [DocChunk] {
        let photos = chunks.filter { c in
            guard c.assetID != nil else { return false }
            if let window { return c.date.map { window.contains($0) } ?? false }
            return true
        }
        return Array(photos.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    }
}
