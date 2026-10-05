import SwiftUI
import UniformTypeIdentifiers

/// Your document library: add files or folders, see what's indexed, and test what a question finds.
struct DocumentsView: View {
    @EnvironmentObject var documents: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var importing = false
    @State private var query = ""
    @State private var results: [DocumentStore.Hit] = []
    @State private var searched = false

    private static let types: [UTType] = {
        var t: [UTType] = [.pdf, .plainText, .rtf, .image, .folder, .commaSeparatedText]
        for ext in ["docx", "xlsx", "md", "markdown"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }()

    var body: some View {
        List {
            Section {
                Button { importing = true } label: {
                    Label("Add files or a folder", systemImage: "plus.circle.fill")
                }
                Text("\(documents.readyCount) document\(documents.readyCount == 1 ? "" : "s") · \(documents.chunks.count) searchable passages")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("PDF, Word (.docx), Excel (.xlsx), text, Markdown, CSV, and photos or scans (read with on-device text recognition). Files are copied into BOT and indexed on your phone. Tip: keep your source files in one folder in iCloud Drive (for example \"BOT Documents\") so you can add or refresh them from the Files picker in one step. Adding a file with the same name replaces the old copy.")
            }

            Section("Documents") {
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
                    .swipeActions { Button(role: .destructive) { documents.remove(d) } label: { Label("Remove", systemImage: "trash") } }
                }
            }

            if !documents.isEmpty {
                Section {
                    TextField("Ask something to test the search", text: $query)
                        .submitLabel(.search)
                        .onSubmit {
                            results = documents.search(query, limit: 5)
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
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { documents.add(urls: urls) }
        }
    }
}
