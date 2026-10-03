import SwiftUI

struct RemindersView: View {
    @EnvironmentObject var reminders: ReminderCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if reminders.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bell.badge").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No reminders").font(.headline)
                        Text("Say something like \"remind me to call Mom at 5\" or \"set a timer for 10 minutes\".")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                }
                ForEach(reminders.items) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.task == ReminderParser.timerTask ? "Timer" : ReminderParser.bannerText(for: r.task))
                            .font(.body)
                        Text(ReminderParser.whenPhrase(r.fire))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button(role: .destructive) { reminders.remove(r) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
