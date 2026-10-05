import SwiftUI
import UniformTypeIdentifiers

/// Your document library: synced folders and photo albums, individual files, and a search tester.
struct DocumentsView: View {
    enum ImportMode { case files, folder }

    @EnvironmentObject var documents: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var importing = false
    @State private var mode: ImportMode = .files
    @State private var showAlbums = false
    @State private var query = ""
    @State private var results: [DocumentStore.Hit] = []
    @State private var searched = false

    private static let fileTypes: [UTType] = {
        var t: [UTType] = [.pdf, .plainText, .rtf, .image, .commaSeparatedText]
        for ext in ["docx", "xlsx", "md", "markdown"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }()

    var body: some View {
        List {
            Section {
                ForEach(documents.sources) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.label).lineLimit(2)
                        Text(statusLine(s)).font(.caption).foregroundStyle(s.status.hasPrefix("failed") ? Color.red : Color.secondary)
                        if let note = s.note { Text(note).font(.caption).foregroundStyle(.orange) }
                    }
                    .swipeActions { Button(role: .destructive) { documents.removeSource(s) } label: { Label("Remove", systemImage: "trash") } }
                }
                Button { mode = .folder; importing = true } label: {
                    Label("Add a synced folder (iCloud Drive or Google Drive)", systemImage: "folder.badge.plus")
                }
                Button { showAlbums = true } label: {
                    Label("Add photo albums", systemImage: "photo.on.rectangle.angled")
                }
                if !documents.sources.isEmpty {
                    Button { documents.rescanAll(force: true) } label: {
                        Label("Check for new and changed files now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } header: { Text("Synced sources") } footer: {
                Text("BOT remembers these folders and albums and checks them for new or changed files each time you open it, so you never re-add anything. For Google Drive, install the Google Drive app and pick a Drive folder here (Files app, Browse, Drive). Google Docs and Sheets are skipped because iOS gives apps only a shortcut to them: upload or export PDFs, Word or Excel files instead. iCloud files that aren't on the phone yet are downloaded as needed.")
            }

            Section {
                Button { mode = .files; importing = true } label: {
                    Label("Add individual files", systemImage: "plus.circle.fill")
                }
                Text("\(documents.readyCount) item\(documents.readyCount == 1 ? "" : "s") · \(documents.chunks.count) searchable passages")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("PDF, Word (.docx), Excel (.xlsx), text, Markdown, CSV, and photos or scans (read with on-device text recognition). Adding a file with the same name replaces the old copy.")
            }

            Section("Library") {
                if documents.docs.isEmpty {
                    Text("Nothing added yet").foregroundStyle(.secondary)
                }
                ForEach(documents.docs) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.name).lineLimit(2)
                        if d.status == "indexing" {
                            ProgressView(value: d.progress)
                            Text("Indexing\u{2026}").font(.caption).foregroundStyle(.secondary)
                        } else if d.status == "ready" {
                            Text("\(d.chunkCount) passages" + (d.pageCount > 0 ? " · \(d.pageCount) page\(d.pageCount == 1 ? "" : "s")" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(d.status).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .swipeActions {
                        if d.sourceID == nil {
                            Button(role: .destructive) { documents.remove(d) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }

            if !documents.isEmpty {
                Section {
                    TextField("Ask something to test the search", text: $query)
                        .submitLabel(.search)
                        .onSubmit {
                            results = documents.search(query, limit: 5, scope: .all)
                            searched = true
                        }
                    if searched && results.isEmpty {
                        Text("No matching passages.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(results) { hit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(hit.chunk.docName + (hit.chunk.location.isEmpty ? "" : " · " + hit.chunk.location))
                                    .font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.2f", hit.score)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(String(hit.chunk.text.prefix(320))).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Test a search") } footer: {
                    Text("Shows the passages BOT would use for a question, with a match score. Scores above about 0.3 count as a real match.")
                }
            }
        }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: mode == .folder ? [.folder] : Self.fileTypes,
                      allowsMultipleSelection: mode == .files) { result in
            guard case .success(let urls) = result else { return }
            if mode == .folder, let folder = urls.first { documents.addFolder(url: folder) } else { documents.add(urls: urls) }
        }
        .sheet(isPresented: $showAlbums) {
            PhotoAlbumsView().environmentObject(documents)
        }
    }

    private func statusLine(_ s: SourceRecord) -> String {
        switch s.status {
        case "ready":
            let unit = s.kind == "photos" ? "photo" : "file"
            let when = s.lastScan.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "just now"
            return "Up to date · \(s.fileCount) \(unit)\(s.fileCount == 1 ? "" : "s") · checked \(when)"
        case "waiting": return "Waiting to check"
        default: return s.status.prefix(1).uppercased() + s.status.dropFirst()
        }
    }
}
