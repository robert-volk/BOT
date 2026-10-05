import Foundation
import AVFoundation
import UserNotifications

struct Reminder: Identifiable, Codable, Equatable {
    var id = UUID()
    var task: String
    var fire: Date
    var repeatRule: String? = nil
}

/// Sent when a calendar meeting begins or ends (for automatic meeting notes).
enum MeetingSignal {
    case start(String)
    case stop
}

enum ScheduleOutcome {
    case scheduled(spokenBanner: Bool)
    case needsPermission
}

/// Reminders = a banner notification + a voice announcement.
///  - App open when it fires: the banner shows and BOT speaks the reminder live.
///  - App closed: iOS shows the banner and plays a short recording of BOT's own voice saying the reminder,
///    which BOT synthesizes on-device when the reminder is set (notification sound, so it follows the
///    ringer volume and the silent switch).
@MainActor
final class ReminderCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var items: [Reminder] = []
    /// Called with the spoken line when a reminder fires while the app is in the foreground.
    var onForegroundFire: ((String) -> Void)?
    /// Called when the daily briefing alarm goes off (or its banner is tapped).
    var onBriefing: (() -> Void)?
    var onMeetingNotes: ((MeetingSignal) -> Void)?
    /// The task of the reminder that most recently went off, so "snooze" knows what to repeat.
    private(set) var lastFiredTask: String?
    private var briefingMinutes: Int?
    private var lastBriefingTrigger = Date.distantPast

    private let fileURL: URL
    private var writers: [String: SoundWriter] = [:]
    private var testPlayer: AVAudioPlayer?

    // Spoken-in-app alerts (works with the silent switch on): timers + a silent audio loop keep BOT alive.
    private struct Alert { var fire: Date; var line: String }
    private var alerts: [String: Alert] = [:]
    private var timers: [String: Timer] = [:]
    private var announced = Set<String>()
    private let keepAlive = SilentKeepAlive()
    var backgroundSpeech = false { didSet { if oldValue != backgroundSpeech { refreshAlerts() } } }

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BOT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("reminders.json")
        super.init()
        UNUserNotificationCenter.current().delegate = self
        load()
        prune()
        for r in items { alerts[r.id.uuidString] = Alert(fire: r.fire, line: ReminderParser.spokenLine(for: r.task)) }
    }

    // MARK: In-app spoken alerts

    func registerAlert(key: String, fire: Date, line: String) {
        alerts[key] = Alert(fire: fire, line: line)
        refreshAlerts()
    }

    func unregisterAlerts(prefix: String) {
        for k in alerts.keys where k.hasPrefix(prefix) { alerts[k] = nil }
        refreshAlerts()
    }

    private func refreshAlerts() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        let now = Date()
        alerts = alerts.filter { $0.value.fire > now.addingTimeInterval(-5) }
        guard backgroundSpeech else { keepAlive.stop(); return }

        for (key, alert) in alerts {
            let delay = max(0.1, alert.fire.timeIntervalSinceNow)
            timers[key] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.timerFired(key: key, line: alert.line) }
            }
        }
        if alerts.values.contains(where: { $0.fire.timeIntervalSinceNow < 24 * 3600 }) {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
    }

    private func timerFired(key: String, line: String) {
        if key.hasPrefix("cal-notes-start-") {
            alerts[key] = nil
            timers[key] = nil
            if announced.insert(key).inserted { onMeetingNotes?(.start(line)) }
            refreshAlerts()
            return
        }
        if key.hasPrefix("cal-notes-stop-") {
            alerts[key] = nil
            timers[key] = nil
            onMeetingNotes?(.stop)
            refreshAlerts()
            return
        }
        if key == "briefing-daily" {
            alerts[key] = nil
            timers[key] = nil
            triggerBriefing()
            registerNextBriefing()
            return
        }
        fired(id: key, spoken: line, speak: true, key: key)
    }

    // MARK: Daily briefing alarm

    func scheduleBriefing(enabled: Bool, minutes: Int) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["briefing-daily"])
        alerts["briefing-daily"] = nil
        briefingMinutes = enabled ? minutes : nil
        guard enabled else { refreshAlerts(); return }
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = "Good morning"
            content.body = "Tap for your daily briefing."
            content.sound = backgroundSpeech ? nil : .default
            content.userInfo = ["briefing": true]
            var dc = DateComponents()
            dc.hour = minutes / 60
            dc.minute = minutes % 60
            let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "briefing-daily", content: content, trigger: trigger))
            registerNextBriefing()
        }
    }

    private func registerNextBriefing() {
        guard let m = briefingMinutes else { return }
        var dc = DateComponents()
        dc.hour = m / 60
        dc.minute = m % 60
        if let next = Calendar.current.nextDate(after: Date().addingTimeInterval(61), matching: dc, matchingPolicy: .nextTime) {
            registerAlert(key: "briefing-daily", fire: next, line: "")
        }
    }

    /// A notification that says "start notes". Ignored once the meeting is over, or if it already started.
    private func startNotes(key: String, title: String, end: Double?) {
        if let end, Date().timeIntervalSince1970 > end { return }
        guard announced.insert(key).inserted else { return }
        onMeetingNotes?(.start(title))
    }

    /// Shows a notification right away (for example "Meeting notes saved").
    func postNow(title: String, body: String, userInfo: [String: Any] = [:]) {
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = backgroundSpeech ? nil : .default
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: "post-\(UUID().uuidString)", content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func triggerBriefing() {
        guard Date().timeIntervalSince(lastBriefingTrigger) > 120 else { return }
        lastBriefingTrigger = Date()
        onBriefing?()
    }

    private func deliver(key: String, line: String) {
        guard announced.insert(key).inserted else { return }   // the timer and the notification both try; speak once
        onForegroundFire?(line)
    }

    // MARK: Scheduling

    func schedule(task: String, fire: Date, voiceID: String?, rate: Float, pitch: Float, repeatRule: String? = nil) async -> ScheduleOutcome {
        guard await ensureAuthorized() else { return .needsPermission }

        let reminder = Reminder(task: task, fire: fire, repeatRule: repeatRule)
        let line = ReminderParser.spokenLine(for: task)
        let soundName: String? = backgroundSpeech ? nil
            : await makeSpeechSound(id: reminder.id, line: String(line.prefix(140)), voiceID: voiceID, rate: rate, pitch: pitch)

        let content = UNMutableNotificationContent()
        content.title = "BOT reminder"
        content.body = ReminderParser.bannerText(for: task)
        if backgroundSpeech {
            content.sound = nil
        } else {
            content.sound = soundName.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        }
        content.userInfo = ["id": reminder.id.uuidString, "spoken": line]

        for (identifier, trigger) in triggers(for: reminder) {
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }

        items.append(reminder)
        items.sort { $0.fire < $1.fire }
        save()
        alerts[reminder.id.uuidString] = Alert(fire: fire, line: line)
        refreshAlerts()
        return .scheduled(spokenBanner: soundName != nil || backgroundSpeech)
    }

    private func triggers(for r: Reminder) -> [(String, UNNotificationTrigger)] {
        guard let rule = r.repeatRule, let kind = ReminderParser.RepeatKind(rule) else {
            return [(r.id.uuidString, UNTimeIntervalNotificationTrigger(timeInterval: max(1, r.fire.timeIntervalSinceNow), repeats: false))]
        }
        let hm = Calendar.current.dateComponents([.hour, .minute], from: r.fire)
        var base = DateComponents()
        base.hour = hm.hour
        base.minute = hm.minute
        let id = r.id.uuidString
        switch kind {
        case .daily:
            return [(id, UNCalendarNotificationTrigger(dateMatching: base, repeats: true))]
        case .weekdays:
            return (2...6).map { d -> (String, UNNotificationTrigger) in
                var c = base
                c.weekday = d
                return ("\(id)#\(d)", UNCalendarNotificationTrigger(dateMatching: c, repeats: true))
            }
        case .weekly(let d):
            var c = base
            c.weekday = d
            return [(id, UNCalendarNotificationTrigger(dateMatching: c, repeats: true))]
        case .monthly(let day):
            var c = base
            c.day = day
            return [(id, UNCalendarNotificationTrigger(dateMatching: c, repeats: true))]
        }
    }

    private func notificationIDs(for r: Reminder) -> [String] {
        let id = r.id.uuidString
        return r.repeatRule == "weekdays" ? (2...6).map { "\(id)#\($0)" } : [id]
    }

    func remove(_ r: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notificationIDs(for: r))
        deleteSound(r.id)
        items.removeAll { $0.id == r.id }
        save()
        alerts[r.id.uuidString] = nil
        refreshAlerts()
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: items.flatMap { notificationIDs(for: $0) })
        items.forEach { deleteSound($0.id) }
        items.removeAll()
        save()
        alerts = alerts.filter { UUID(uuidString: $0.key) == nil }   // keep calendar + briefing alerts
        refreshAlerts()
    }

    func spokenList() -> String {
        prune()
        guard !items.isEmpty else { return "You don't have any reminders set." }
        let parts = items.prefix(4).map { r -> String in
            let when = r.repeatRule.map { ReminderParser.repeatPhrase($0, at: r.fire) } ?? ReminderParser.whenPhrase(r.fire)
            return "\(ReminderParser.secondPerson(r.task)), \(when)"
        }
        let count = items.count == 1 ? "You have one reminder." : "You have \(items.count) reminders."
        return count + " " + parts.joined(separator: ". ") + "."
    }

    func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    // MARK: Spoken notification sound

    static var soundsDirectory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Sounds", isDirectory: true)
    }

    private func deleteSound(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.soundsDirectory.appendingPathComponent("bot-\(id.uuidString).caf"))
    }

    /// Renders `line` with BOT's voice into Library/Sounds so a notification can play it with the app closed.
    private func makeSpeechSound(id: UUID, line: String, voiceID: String?, rate: Float, pitch: Float) async -> String? {
        await speechSound(named: "bot-\(id.uuidString).caf", line: line, voiceID: voiceID, rate: rate, pitch: pitch)
    }

    /// Renders `line` to Library/Sounds/<name>, reusing an existing file with that name.
    func speechSound(named name: String, line: String, voiceID: String?, rate: Float, pitch: Float) async -> String? {
        try? FileManager.default.createDirectory(at: Self.soundsDirectory, withIntermediateDirectories: true)
        let url = Self.soundsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }

        // Premium/Enhanced voices often can't be rendered to a file, so fall back to the built-in Samantha.
        var voices: [AVSpeechSynthesisVoice] = []
        if let v = voiceID.flatMap({ AVSpeechSynthesisVoice(identifier: $0) }) ?? Speaker.bestVoice() { voices.append(v) }
        if let v = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha") { voices.append(v) }
        if let v = AVSpeechSynthesisVoice(language: "en-US") { voices.append(v) }

        for voice in voices {
            let u = AVSpeechUtterance(string: line)
            u.voice = voice
            u.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate
            u.pitchMultiplier = pitch

            let writer = SoundWriter(url: url)
            writers[name] = writer
            let ok = await writer.render(u)
            writers[name] = nil
            if ok { return name }
            try? FileManager.default.removeItem(at: url)
        }
        return nil
    }

    // MARK: Diagnostics

    /// Checks notification settings, renders BOT's voice to a file, plays it in-app, and schedules a test alert in 10 s.
    func runAlertTest(voiceID: String?, rate: Float, pitch: Float) async -> [String] {
        var out: [String] = []
        guard await ensureAuthorized() else {
            return ["Notifications are OFF for BOT. Turn them on in iPhone Settings > Notifications > BOT."]
        }
        let center = UNUserNotificationCenter.current()
        let s = await center.notificationSettings()
        func word(_ v: UNNotificationSetting) -> String { v == .enabled ? "on" : (v == .disabled ? "OFF" : "n/a") }
        out.append("Banners: \(word(s.alertSetting)), Sounds: \(word(s.soundSetting)), Lock Screen: \(word(s.lockScreenSetting))")
        if s.soundSetting != .enabled {
            out.append("FIX: Sounds are off for BOT. Turn on Settings > Notifications > BOT > Sounds.")
        }

        let name = "bot-test.caf"
        let url = Self.soundsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        Listener.configureAudioSession()
        let rendered = await speechSound(named: name, line: "This is a test of my spoken alert.",
                                         voiceID: voiceID, rate: rate, pitch: pitch)
        if rendered == nil {
            out.append("FAIL: could not record BOT's voice to a file with any voice, so alerts use the default chime.")
        } else {
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            if let f = try? AVAudioFile(forReading: url) {
                let secs = Double(f.length) / f.fileFormat.sampleRate
                out.append(String(format: "OK: voice file recorded: %.1f s, %d Hz, %d KB", secs, Int(f.fileFormat.sampleRate), bytes / 1024))
            } else {
                out.append("FAIL: the recorded file can't be read back (\(bytes) bytes).")
            }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                testPlayer = player
                player.play()
                out.append("Playing the file now. Did you hear BOT say a test sentence? If yes, the file is fine.")
            } else {
                out.append("FAIL: the file can't be played.")
            }
        }

        let content = UNMutableNotificationContent()
        content.title = "BOT sound test"
        content.body = rendered == nil ? "You should hear the default chime." : "You should hear BOT's voice."
        if backgroundSpeech {
            content.sound = nil
            content.body = "BOT will say the test sentence itself."
            registerAlert(key: "bot-test", fire: Date().addingTimeInterval(10), line: "This is a test of my spoken alert.")
        } else {
            content.sound = rendered.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        }
        let request = UNNotificationRequest(identifier: "bot-test", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false))
        try? await center.add(request)
        out.append("Test alert arrives in 10 seconds. Press the side button to lock the phone now, with the ringer switch off (no orange).")
        return out
    }

    // MARK: Delivery

    private func fired(id: String?, spoken: String?, speak: Bool, key: String? = nil) {
        if let key {
            alerts[key] = nil
            timers[key]?.invalidate()
            timers[key] = nil
        }
        if let id, let uuid = UUID(uuidString: id), let idx = items.firstIndex(where: { $0.id == uuid }) {
            lastFiredTask = items[idx].task
            if let rule = items[idx].repeatRule, let kind = ReminderParser.RepeatKind(rule) {
                // Repeating: keep it, and move it to the next occurrence.
                let hm = Calendar.current.dateComponents([.hour, .minute], from: items[idx].fire)
                if let next = ReminderParser.nextOccurrence(kind, hour: hm.hour ?? 8, minute: hm.minute ?? 0,
                                                            after: Date().addingTimeInterval(61)) {
                    items[idx].fire = next
                    alerts[uuid.uuidString] = Alert(fire: next, line: ReminderParser.spokenLine(for: items[idx].task))
                    save()
                }
            } else {
                deleteSound(uuid)
                items.remove(at: idx)
                save()
            }
        }
        if speak, let spoken { deliver(key: key ?? id ?? spoken, line: spoken) }
        refreshAlerts()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        if info["briefing"] != nil {
            Task { @MainActor in self.triggerBriefing() }
            completionHandler([.banner, .list])
            return
        }
        if let title = info["notesStart"] as? String {
            let end = info["notesEnd"] as? Double
            let key = notification.request.identifier
            Task { @MainActor in self.startNotes(key: key, title: title, end: end) }
            completionHandler([.banner, .list])
            return
        }
        let id = info["id"] as? String
        let spoken = info["spoken"] as? String
        let key = notification.request.identifier
        Task { @MainActor in self.fired(id: id, spoken: spoken, speak: true, key: key) }
        completionHandler([.banner, .list])   // BOT speaks it itself, so no notification sound here
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if info["briefing"] != nil {
            Task { @MainActor in self.triggerBriefing() }
            completionHandler()
            return
        }
        if let title = info["notesStart"] as? String {
            let end = info["notesEnd"] as? Double
            let key = response.notification.request.identifier
            Task { @MainActor in self.startNotes(key: key, title: title, end: end) }
            completionHandler()
            return
        }
        let id = info["id"] as? String
        Task { @MainActor in self.fired(id: id, spoken: nil, speak: false) }
        completionHandler()
    }

    // MARK: Persistence

    private func prune() {
        let now = Date()
        for i in items.indices where items[i].repeatRule != nil && items[i].fire < now.addingTimeInterval(-60) {
            if let rule = items[i].repeatRule, let kind = ReminderParser.RepeatKind(rule) {
                let hm = Calendar.current.dateComponents([.hour, .minute], from: items[i].fire)
                if let next = ReminderParser.nextOccurrence(kind, hour: hm.hour ?? 8, minute: hm.minute ?? 0, after: now) {
                    items[i].fire = next
                }
            }
        }
        let stale = items.filter { $0.repeatRule == nil && $0.fire < now.addingTimeInterval(-60) }
        stale.forEach { deleteSound($0.id) }
        if !stale.isEmpty { items.removeAll { r in stale.contains { $0.id == r.id } } }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Reminder].self, from: data) else { return }
        items = decoded.sorted { $0.fire < $1.fire }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Renders an utterance to a 16-bit PCM .caf file using AVSpeechSynthesizer.write.
private final class SoundWriter: @unchecked Sendable {
    private let url: URL
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var done = false
    private var continuation: CheckedContinuation<Bool, Never>?

    init(url: URL) { self.url = url }

    func render(_ utterance: AVSpeechUtterance) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock(); continuation = cont; lock.unlock()

            synth.write(utterance) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { self.finish(requireFile: true); return }
                self.append(pcm)
            }
            // Never hang: some voices don't produce buffers.
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(requireFile: false, forceFail: true) }
        }
    }

    private func append(_ pcm: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        do {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: pcm.format.sampleRate,
                    AVNumberOfChannelsKey: pcm.format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            file = nil
        }
    }

    private func finish(requireFile: Bool, forceFail: Bool = false) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let ok = !forceFail && file != nil
        file = nil            // closes and flushes the file
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: ok)
    }
}
