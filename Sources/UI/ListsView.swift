import SwiftUI

/// Your voice-managed lists and notes.
struct ListsView: View {
    @EnvironmentObject var lists: ListStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if lists.data.lists.isEmpty && lists.data.notes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checklist").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Nothing here yet").font(.headline)
                        Text("Say \"add milk and eggs to my grocery list\" or \"take a note: call the plumber\".")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                }
                ForEach(lists.listNames, id: \.self) { name in
                    Section(name.capitalized) {
                        ForEach(lists.items(in: name), id: \.self) { item in
                            Text(item)
                        }
                        .onDelete { lists.removeItem(at: $0, in: name) }
                    }
                }
                if !lists.data.notes.isEmpty {
                    Section("Notes") {
                        ForEach(lists.data.notes) { note in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.text)
                                Text(note.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { lists.deleteNotes(at: $0) }
                    }
                }
            }
            .navigationTitle("Lists & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
