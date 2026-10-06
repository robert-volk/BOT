import SwiftUI

struct RemindersView: View {
    @EnvironmentObject var reminders: ReminderCenter
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if reminders.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bell.badge").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No announcements").font(.headline)
                        Text("Tap + to add one, or say \"remind me to call Mom at 5\" or \"set a timer for 10 minutes\".")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                }
                ForEach(reminders.items) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.task == ReminderParser.timerTask ? "Timer" : ReminderParser.bannerText(for: r.task))
                            .font(.body)
                        Text(r.repeatRule.map { ReminderParser.repeatPhrase($0, at: r.fire) } ?? ReminderParser.whenPhrase(r.fire))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button(role: .destructive) { reminders.remove(r) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            .navigationTitle("Announcements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add announcement")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $adding) { AddAnnouncementView() }
        }
    }
}

/// A form for adding your own announcement: what BOT should say, when, and how often.
struct AddAnnouncementView: View {
    @EnvironmentObject var reminders: ReminderCenter
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Frequency: String, CaseIterable, Identifiable {
        case once = "Once", daily = "Every day", weekdays = "Weekdays", weekly = "Every week", monthly = "Every month"
        var id: String { rawValue }
    }

    @State private var message = ""
    @State private var frequency = Frequency.once
    @State private var when = Date().addingTimeInterval(3600)
    @State private var weekday = Calendar.current.component(.weekday, from: Date())
    @State private var monthDay = Calendar.current.component(.day, from: Date())
    @State private var error: String?
    @State private var saving = false

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should BOT say?", text: $message, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    Text("For example: \"take your vitamins\", \"time to leave for school pickup\", \"stand up and stretch\". BOT shows a banner and says it out loud.")
                }

                Section("When") {
                    Picker("Repeat", selection: $frequency) {
                        ForEach(Frequency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if frequency == .once {
                        DatePicker("Date and time", selection: $when, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    } else {
                        DatePicker("Time", selection: $when, displayedComponents: .hourAndMinute)
                    }
                    if frequency == .weekly {
                        Picker("Day", selection: $weekday) {
                            ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                    }
                    if frequency == .monthly {
                        Picker("Day of the month", selection: $monthDay) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.subheadline) }
                }
            }
            .navigationTitle("New announcement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(trimmed.count < 2 || saving)
                }
            }
        }
    }

    private func save() {
        error = nil
        let rule: String?
        switch frequency {
        case .once: rule = nil
        case .daily: rule = "daily"
        case .weekdays: rule = "weekdays"
        case .weekly: rule = "weekly:\(weekday)"
        case .monthly: rule = "monthly:\(monthDay)"
        }
        var fire = when
        if rule == nil {
            guard fire > Date().addingTimeInterval(5) else { error = "Pick a time in the future."; return }
        } else {
            let resolved = ReminderParser.finalizeRepeat(rule: rule, date: when)
            guard resolved.rule != nil else { error = "Couldn't work out that schedule."; return }
            fire = resolved.date
        }
        saving = true
        let prefs = settings.prefs
        Task {
            let outcome = await reminders.schedule(task: trimmed, fire: fire, voiceID: prefs.voiceID,
                                                   rate: Float(prefs.rate), pitch: Float(prefs.pitch), repeatRule: rule)
            saving = false
            switch outcome {
            case .scheduled: dismiss()
            case .needsPermission:
                error = "Turn on notifications for BOT in the iPhone Settings app, then try again."
            }
        }
    }
}
