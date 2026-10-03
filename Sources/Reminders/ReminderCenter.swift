import Foundation
import AVFoundation
import UserNotifications

struct Reminder: Identifiable, Codable, Equatable {
    var id = UUID()
    var task: String
    var fire: Date
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

    private let fileURL: URL
    private var writers: [String: SoundWriter] = [:]

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BOT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("reminders.json")
        super.init()
        UNUserNotificationCenter.current().delegate = self
        load()
        prune()
    }

    // MARK: Scheduling

    func schedule(task: String, fire: Date, voiceID: String?, rate: Float, pitch: Float) async -> ScheduleOutcome {
        guard await ensureAuthorized() else { return .needsPermission }

        let reminder = Reminder(task: task, fire: fire)
        let line = ReminderParser.spokenLine(for: task)
        let soundName = await makeSpeechSound(id: reminder.id, line: String(line.prefix(140)), voiceID: voiceID, rate: rate, pitch: pitch)

        let content = UNMutableNotificationContent()
        content.title = "BOT reminder"
        content.body = ReminderParser.bannerText(for: task)
        content.sound = soundName.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        content.userInfo = ["id": reminder.id.uuidString, "spoken": line]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)

        items.append(reminder)
        items.sort { $0.fire < $1.fire }
        save()
        return .scheduled(spokenBanner: soundName != nil)
    }

    func remove(_ r: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [r.id.uuidString])
        deleteSound(r.id)
        items.removeAll { $0.id == r.id }
        save()
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        items.forEach { deleteSound($0.id) }
        items.removeAll()
        save()
    }

    func spokenList() -> String {
        prune()
        guard !items.isEmpty else { return "You don't have any reminders set." }
        let parts = items.prefix(4).map { "\(ReminderParser.secondPerson($0.task)), \(ReminderParser.whenPhrase($0.fire))" }
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

    // MARK: Delivery

    private func fired(id: String?, spoken: String?, speak: Bool) {
        if let id, let uuid = UUID(uuidString: id) {
            deleteSound(uuid)
            items.removeAll { $0.id == uuid }
            save()
        }
        if speak, let spoken { onForegroundFire?(spoken) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let id = info["id"] as? String
        let spoken = info["spoken"] as? String
        Task { @MainActor in self.fired(id: id, spoken: spoken, speak: true) }
        completionHandler([.banner, .list])   // BOT speaks it itself, so no notification sound here
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String
        Task { @MainActor in self.fired(id: id, spoken: nil, speak: false) }
        completionHandler()
    }

    // MARK: Persistence

    private func prune() {
        let stale = items.filter { $0.fire < Date().addingTimeInterval(-60) }
        stale.forEach { deleteSound($0.id) }
        if !stale.isEmpty {
            items.removeAll { r in stale.contains { $0.id == r.id } }
            save()
        }
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
