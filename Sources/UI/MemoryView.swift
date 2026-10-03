import SwiftUI

/// Everything BOT has learned about you. Edit, pin, delete, or add facts yourself.
struct MemoryView: View {
    @EnvironmentObject var facts: FactStore
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Fact?
    @State private var editText = ""
    @State private var adding = false
    @State private var addText = ""
    @State private var confirmClear = false

    var body: some View {
        List {
            if facts.facts.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "brain.head.profile").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Nothing yet").font(.headline)
                        Text("Just talk to BOT. It picks up things like your name, family, work and what you like, and remembers them here.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            ForEach(FactCategory.allCases) { cat in
                let items = facts.facts.filter { $0.category == cat }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { fact in
                            HStack {
                                if fact.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                                Text(fact.text)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = fact; editText = fact.text }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { facts.remove(fact) } label: { Label("Delete", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { facts.togglePin(fact) } label: { Label(fact.pinned ? "Unpin" : "Pin", systemImage: "pin") }
                                    .tint(.orange)
                            }
                        }
                    } header: {
                        Label(cat.title, systemImage: cat.symbol)
                    }
                }
            }
            if !facts.facts.isEmpty {
                Section {
                    Button("Forget everything", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Tap a fact to edit it. Swipe right to pin (pinned facts are always remembered), left to delete.")
                }
            }
        }
        .navigationTitle("What BOT knows")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addText = ""; adding = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("Edit fact", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Fact", text: $editText)
            Button("Save") { if let f = editing { facts.update(f, text: editText) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .alert("Add a fact", isPresented: $adding) {
            TextField("e.g. Has a dog named Max", text: $addText)
            Button("Add") { facts.add(addText, category: .other, pinned: true) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Erase everything BOT knows about you?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Forget everything", role: .destructive) { facts.clear() }
        }
    }
}
