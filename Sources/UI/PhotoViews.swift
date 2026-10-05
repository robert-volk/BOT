import SwiftUI

/// Choose which photo albums BOT should read.
struct PhotoAlbumsView: View {
    @EnvironmentObject var documents: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var albums: [PhotoIndexer.Album] = []
    @State private var selected = Set<String>()
    @State private var denied = false
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if denied {
                    Text("Photos access is off. Turn it on for BOT in iPhone Settings, Privacy and Security, Photos.")
                        .foregroundStyle(.red)
                } else if loading {
                    ProgressView()
                } else {
                    Section {
                        ForEach(albums) { a in
                            Toggle(isOn: Binding(get: { selected.contains(a.id) },
                                                 set: { on in if on { selected.insert(a.id) } else { selected.remove(a.id) } })) {
                                VStack(alignment: .leading) {
                                    Text(a.name)
                                    Text("\(a.count) photos").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } footer: {
                        Text("BOT reads the newest 300 photos per check, then more each time you check again. It looks for visible text (receipts, signs, screenshots) and what the picture shows, all on your phone. Photos in iCloud are downloaded as needed, which uses data and battery. Photo text is never sent to Claude.")
                    }
                }
            }
            .navigationTitle("Photo albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let chosen = albums.filter { selected.contains($0.id) }.map { (id: $0.id, name: $0.name) }
                        documents.addPhotos(albums: chosen)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .task {
                guard await PhotoIndexer.authorize() else {
                    denied = true
                    loading = false
                    return
                }
                albums = PhotoIndexer.albums()
                loading = false
            }
        }
    }
}

/// The photos BOT found for a question.
struct PhotoPreviewView: View {
    let assetIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var images: [String: UIImage] = [:]

    var body: some View {
        NavigationStack {
            TabView {
                ForEach(assetIDs, id: \.self) { id in
                    Group {
                        if let image = images[id] {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .padding()
                }
            }
            .tabViewStyle(.page)
            .navigationTitle("\(assetIDs.count) photo\(assetIDs.count == 1 ? "" : "s") found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                for id in assetIDs {
                    images[id] = await PhotoIndexer.loadImage(id, side: 2000)
                }
            }
        }
    }
}
