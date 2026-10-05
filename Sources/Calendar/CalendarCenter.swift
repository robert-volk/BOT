import Foundation
import EventKit
import CoreLocation
import UserNotifications

/// Reads your calendar (EventKit, only after you allow it) to:
///  - schedule a banner + spoken heads-up before each upcoming meeting,
///  - answer "what's on my calendar today?" / "when's my next meeting?",
///  - give the on-device AI a short view of your next two days.
/// Nothing is written to your calendar, and nothing leaves the phone except, if you opt in, a short schedule
/// summary in the prompt sent to Claude.
@MainActor
final class CalendarCenter: ObservableObject {
    @Published private(set) var authorized = false
    /// Set by the engine: facts BOT remembers that mention a person's first name.
    var factsProvider: ((String) -> [String])?

    private let store = EKEventStore()
    private let reminders: ReminderCenter
    private var syncing = false
    private var queuedPrefs: Preferences?
    private static let idPrefix = "cal-"
    private static let soundPrefix = "bot-cal-"

    init(reminders: ReminderCenter) {
        self.reminders = reminders
        refreshAuthorization()
    }

    // MARK: Access

    func refreshAuthorization() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var isDenied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    func requestAccess() async -> Bool {
        if authorized { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        refreshAuthorization()
        return granted
    }

    // MARK: Events

    func events(from start: Date, to end: Date, includeAllDay: Bool = false) -> [EKEvent] {
        guard authorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { e in
                if e.status == .canceled { return false }
                if !includeAllDay && e.isAllDay { return false }
                if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return false }
                return true
            }
            .sorted { $0.startDate < $1.startDate }
    }

    private func title(_ e: EKEvent) -> String {
        let t = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "an event" : String(t.prefix(60))
    }

    private func place(_ e: EKEvent) -> String {
        guard let loc = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else { return "" }
        return String(loc.prefix(50))
    }

    // MARK: Meeting alerts

    /// (Re)schedules alerts for the next three days. Safe to call often; it replaces earlier calendar alerts.
    func sync(with prefs: Preferences) async {
        if syncing { queuedPrefs = prefs; return }
        syncing = true
        var current: Preferences? = prefs
        while let p = current {
            await runSync(p)
            current = queuedPrefs
            queuedPrefs = nil
        }
        syncing = false
    }

    private func runSync(_ prefs: Preferences) async {
        refreshAuthorization()
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let old = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        reminders.unregisterAlerts(prefix: Self.idPrefix)

        guard prefs.calendarAlerts, authorized, await reminders.ensureAuthorized() else {
            cleanSounds(keeping: [])
            return
        }

        let lead = max(0, prefs.calendarLead)
        let now = Date()
        let upcoming = events(from: now, to: now.addingTimeInterval(3 * 86400)).prefix(24)
        var keep = Set<String>()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"

        var here: CLLocation?
        var triedHere = false
        var leaveCount = 0

        for e in upcoming {
            if prefs.leaveAlerts, leaveCount < 6, e.startDate.timeIntervalSince(now) < 24 * 3600 {
                if !triedHere {
                    triedHere = true
                    here = await LocationService.shared.current()
                }
                if let here, await scheduleLeaveAlert(for: e, from: here, prefs: prefs, now: now, keep: &keep) { leaveCount += 1 }
            }
            if prefs.autoMeetingNotes, Self.qualifiesForNotes(e) {
                await scheduleMeetingNotes(for: e, now: now, silent: prefs.speakInBackground)
            }
            let fire = e.startDate.addingTimeInterval(-Double(lead) * 60)
            guard fire.timeIntervalSince(now) > 2 else { continue }
            let name = title(e)
            var line = lead == 0
                ? "Your meeting, \(name), is starting now."
                : "Heads up. \(name) starts in \(lead) minutes."
            if prefs.meetingPrep {
                let details = prepDetails(e)
                if !details.isEmpty { line += " " + details }
                line = String(line.prefix(320))
            }

            let soundFile = Self.soundPrefix + Self.hash(line) + ".caf"
            var rendered: String?
            if !prefs.speakInBackground {
                rendered = await reminders.speechSound(named: soundFile, line: line, voiceID: prefs.voiceID,
                                                       rate: Float(prefs.rate), pitch: Float(prefs.pitch))
            }
            if rendered != nil { keep.insert(soundFile) }

            let content = UNMutableNotificationContent()
            content.title = lead == 0 ? "Starting now" : "Starting in \(lead) minutes"
            content.subtitle = name
            let loc = place(e)
            content.body = timeFmt.string(from: e.startDate) + (loc.isEmpty ? "" : " · \(loc)")
            if prefs.speakInBackground {
                content.sound = nil
            } else {
                content.sound = rendered.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
            }
            content.threadIdentifier = "bot-calendar"
            content.userInfo = ["spoken": line]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
            let id = Self.idPrefix + (e.eventIdentifier ?? name) + "-\(Int(e.startDate.timeIntervalSince1970))"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            reminders.registerAlert(key: id, fire: fire, line: line)
        }
        cleanSounds(keeping: keep)
    }

    /// Real meetings only: other attendees or a location, between 10 minutes and 3 hours long.
    private static func qualifiesForNotes(_ e: EKEvent) -> Bool {
        let length = e.endDate.timeIntervalSince(e.startDate)
        guard !e.isAllDay, length >= 600, length <= 3 * 3600 else { return false }
        return e.hasAttendees || !(e.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// At the start time: start notes (automatically if BOT is running, otherwise via a tap on the banner).
    /// At the end time: stop them.
    private func scheduleMeetingNotes(for e: EKEvent, now: Date, silent: Bool) async {
        let name = title(e)
        let base = (e.eventIdentifier ?? name) + "-\(Int(e.startDate.timeIntervalSince1970))"
        if e.startDate.timeIntervalSince(now) > 2 {
            let content = UNMutableNotificationContent()
            content.title = "Meeting starting"
            content.body = "Tap to take notes: \(name)"
            if silent { content.sound = nil } else { content.sound = UNNotificationSound.default }
            content.threadIdentifier = "bot-calendar"
            content.userInfo = ["notesStart": name, "notesEnd": e.endDate.timeIntervalSince1970]
            let id = Self.idPrefix + "notes-start-" + base
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: e.startDate.timeIntervalSince(now), repeats: false)
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            reminders.registerAlert(key: id, fire: e.startDate, line: name)
        }
        if e.endDate.timeIntervalSince(now) > 60 {
            reminders.registerAlert(key: Self.idPrefix + "notes-stop-" + base, fire: e.endDate, line: name)
        }
    }

    private static func isVirtual(_ location: String) -> Bool {
        let l = location.lowercased()
        return ["http", "zoom", "teams", "meet.google", "webex", "video", "online", "phone", "call"].contains { l.contains($0) }
    }

    /// "Time to leave for X, it's about N minutes away", based on Apple Maps drive time from where you are now.
    private func scheduleLeaveAlert(for e: EKEvent, from here: CLLocation, prefs: Preferences, now: Date,
                                    keep: inout Set<String>) async -> Bool {
        let loc = place(e)
        guard !loc.isEmpty, !Self.isVirtual(loc) else { return false }
        let maps = LocationService.shared
        var coordinate = e.structuredLocation?.geoLocation?.coordinate
        if coordinate == nil { coordinate = await maps.geocode(loc) }
        guard let destination = coordinate,
              let minutes = await maps.driveMinutes(from: here, to: destination, departure: e.startDate.addingTimeInterval(-1800))
        else { return false }

        let fire = e.startDate.addingTimeInterval(-Double(minutes + 5) * 60)
        guard fire.timeIntervalSince(now) > 2 else { return false }

        let name = title(e)
        let line = "Time to leave for \(name). It's about \(minutes) minutes away."
        let soundFile = Self.soundPrefix + Self.hash(line) + ".caf"
        var rendered: String?
        if !prefs.speakInBackground {
            rendered = await reminders.speechSound(named: soundFile, line: line, voiceID: prefs.voiceID,
                                                   rate: Float(prefs.rate), pitch: Float(prefs.pitch))
        }
        if rendered != nil { keep.insert(soundFile) }

        let content = UNMutableNotificationContent()
        content.title = "Time to leave"
        content.subtitle = name
        content.body = "About \(minutes) min drive · \(loc)"
        if prefs.speakInBackground {
            content.sound = nil
        } else {
            content.sound = rendered.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        }
        content.threadIdentifier = "bot-calendar"
        content.userInfo = ["spoken": line]

        let id = Self.idPrefix + "leave-" + (e.eventIdentifier ?? name) + "-\(Int(e.startDate.timeIntervalSince1970))"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        reminders.registerAlert(key: id, fire: fire, line: line)
        return true
    }

    private func cleanSounds(keeping keep: Set<String>) {
        let dir = ReminderCenter.soundsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix(Self.soundPrefix) && !keep.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    private static func hash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        return String(h, radix: 16)
    }

    // MARK: Voice questions

    static func isAgendaQuestion(_ text: String) -> Bool {
        if isPrepRequest(text) { return true }
        let l = text.lowercased()
        func has(_ p: String) -> Bool { l.range(of: p, options: .regularExpression) != nil }
        guard has(#"\b(calendar|schedule|agenda|meetings?|appointments?)\b"#) else { return false }
        if has(#"\b(schedule|set up|book|create|add|cancel|move|reschedule)\b.*\b(a|an|the|me|new)\b.*\b(meeting|appointment|event)\b"#) { return false }
        return has(#"\b(what|what's|whats|when|when's|do i have|any|anything|next|am i|how many|read|tell me|check|show)\b"#)
    }

    func spokenAgenda(for text: String) -> String {
        guard authorized else {
            return "I can't see your calendar yet. Turn on Calendars for BOT in iPhone Settings, Privacy and Security."
        }
        let now = Date()
        let cal = Calendar.current
        let lower = text.lowercased()

        if Self.isPrepRequest(text) { return spokenPrep() }

        if lower.contains("next") {
            guard let e = events(from: now, to: now.addingTimeInterval(7 * 86400)).first(where: { $0.startDate > now }) else {
                return "You don't have any meetings coming up in the next week."
            }
            let loc = place(e)
            return "Your next event is \(title(e)) \(ReminderParser.whenPhrase(e.startDate))" + (loc.isEmpty ? "." : ", at \(loc).")
        }

        var dayStart = cal.startOfDay(for: now)
        var days = 1
        var label = "today"
        var fromNow = true
        if lower.contains("tomorrow") {
            dayStart = cal.date(byAdding: .day, value: 1, to: dayStart)!
            label = "tomorrow"
            fromNow = false
        } else if lower.contains("week") {
            days = 7
            label = "this week"
        } else if let d = Self.detectDate(in: text), !cal.isDateInToday(d) {
            dayStart = cal.startOfDay(for: d)
            let f = DateFormatter(); f.dateFormat = "EEEE"
            label = "on " + f.string(from: d)
            fromNow = false
        }
        let end = cal.date(byAdding: .day, value: days, to: dayStart)!
        let all = events(from: fromNow ? now : dayStart, to: end, includeAllDay: true)
        let timed = all.filter { !$0.isAllDay }
        let allDay = all.filter { $0.isAllDay }

        if timed.isEmpty && allDay.isEmpty {
            return label == "today" ? "You have nothing else on your calendar today." : "You have nothing on your calendar \(label)."
        }

        var reply = ""
        if !timed.isEmpty {
            let items = timed.prefix(5).map { "\(title($0)) \(ReminderParser.whenPhrase($0.startDate))" }
            let count = timed.count == 1 ? "one event" : "\(timed.count) events"
            reply += "You have \(count) \(label == "today" ? "left today" : label): " + Self.joined(items) + "."
            if timed.count > 5 { reply += " Plus \(timed.count - 5) more." }
        }
        if !allDay.isEmpty {
            reply += (reply.isEmpty ? "" : " ") + "All day: " + Self.joined(allDay.prefix(3).map { title($0) }) + "."
        }
        return reply
    }

    /// A few lines for the AI's prompt so it can answer things like "am I free at 3?".
    func promptBlock() -> String {
        guard authorized else { return "" }
        let now = Date()
        let evs = events(from: now, to: now.addingTimeInterval(2 * 86400)).prefix(8)
        guard !evs.isEmpty else { return "Nothing on their calendar in the next two days." }
        return evs.map { e in
            let loc = place(e)
            return "- \(title(e)), \(ReminderParser.whenPhrase(e.startDate))" + (loc.isEmpty ? "" : " (\(loc))")
        }.joined(separator: "\n")
    }

    // MARK: Meeting prep

    static func isPrepRequest(_ text: String) -> Bool {
        text.range(of: #"\b(?:prep|prepare|brief)\s+(?:me\s+)?(?:for|on)\s+(?:my |the )?(?:next |upcoming )?(?:meeting|call)\b|\bprep(?:are)? me\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Who's attending, where it is, your own notes on the event, and anything BOT remembers about the people.
    func prepDetails(_ e: EKEvent) -> String {
        var parts: [String] = []
        let people = (e.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .compactMap { $0.name }
            .filter { !$0.contains("@") }
            .map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        if !people.isEmpty {
            let shown = Array(people.prefix(3))
            let others = people.count - shown.count
            parts.append("With " + ListStore.joined(shown) + (others > 0 ? " and \(others) other\(others == 1 ? "" : "s")" : "") + ".")
        }
        let loc = place(e)
        if !loc.isEmpty, !Self.isVirtual(loc) { parts.append("At \(loc).") }
        if let notes = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let first = notes.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? notes
            parts.append("Notes say: " + String(first.prefix(140)) + ".")
        }
        var remembered: [String] = []
        for person in people.prefix(3) {
            if let fact = factsProvider?(person).first { remembered.append(fact) }
        }
        if !remembered.isEmpty { parts.append("I remember: " + remembered.prefix(2).joined(separator: "; ") + ".") }
        return parts.joined(separator: " ")
    }

    func spokenPrep() -> String {
        guard authorized else { return "I can't see your calendar yet. Turn on Calendars for BOT in iPhone Settings, Privacy and Security." }
        let now = Date()
        guard let e = events(from: now, to: now.addingTimeInterval(24 * 3600)).first(where: { $0.startDate > now }) else {
            return "You don't have any more meetings in the next day."
        }
        let details = prepDetails(e)
        return "Your next meeting is \(title(e)) \(ReminderParser.whenPhrase(e.startDate)). " + (details.isEmpty ? "I don't have more details on it." : details)
    }

    // MARK: Helpers

    private static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    private static func detectDate(in text: String) -> Date? {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        return det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
    }
}
