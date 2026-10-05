import SwiftUI

/// Your voice-managed lists, notes, meeting notes, journal and saved parking spot.
struct ListsView: View {
    @EnvironmentObject var lists: ListStore
    @Environment(\.dismiss) private var dismiss

    private var isEmpty: Bool {
        lists.data.lists.isEmpty && lists.data.notes.isEmpty && lists.meetings.isEmpty
            && lists.journal.isEmpty && lists.data.parking == nil
    }

    var body: some View {
        NavigationStack {
            List {
                if isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checklist").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Nothing here yet").font(.headline)
                        Text("Say \"add milk and eggs to my grocery list\", \"take notes on this meeting\", \"start my journal\" or \"remember where I parked\".")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                }

                if let spot = lists.data.parking {
                    Section("Parked") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Near \(spot.place)")
                            if !spot.note.isEmpty { Text(spot.note).font(.subheadline) }
                            Text(spot.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button(role: .destructive) { lists.clearParking() } label: { Label("Clear", systemImage: "trash") } }
                    }
                }

                ForEach(lists.listNames, id: \.self) { name in
                    Section(name.capitalized) {
                        ForEach(lists.items(in: name), id: \.self) { item in
                            Text(item)
                        }
                        .onDelete { lists.removeItem(at: $0, in: name) }
                    }
                }

                if !lists.meetings.isEmpty {
                    Section("Meeting notes") {
                        ForEach(Array(lists.meetings.reversed())) { m in
                            DisclosureGroup {
                                Text(m.summary).font(.subheadline)
                                if !m.actions.isEmpty {
                                    ForEach(m.actions, id: \.self) { a in Label(a, systemImage: "circle").font(.footnote) }
                                }
                                Text(m.transcript).font(.caption).foregroundStyle(.secondary)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.date, style: .date)
                                    Text("\(m.minutes) min").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button(role: .destructive) { lists.deleteMeeting(m) } label: { Label("Delete", systemImage: "trash") } }
                        }
                    }
                }

                if !lists.journal.isEmpty {
                    Section("Journal") {
                        ForEach(Array(lists.journal.reversed())) { e in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(e.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    if let mood = e.mood { Text(mood).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                                }
                                Text(e.text).font(.subheadline)
                            }
                            .swipeActions { Button(role: .destructive) { lists.deleteJournal(e) } label: { Label("Delete", systemImage: "trash") } }
                        }
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
