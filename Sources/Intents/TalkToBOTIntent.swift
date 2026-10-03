import AppIntents
import Foundation

extension Notification.Name {
    static let botWakeRequested = Notification.Name("botWakeRequested")
}

/// Bridges Siri / Shortcuts / the Action Button into the running app.
@MainActor
final class LaunchSignal {
    static let shared = LaunchSignal()
    var pending = false

    func request() {
        pending = true
        NotificationCenter.default.post(name: .botWakeRequested, object: nil)
    }

    /// True once per request.
    func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

/// "Hey Siri, talk to BOT": opens BOT and starts listening right away.
struct TalkToBOTIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to BOT"
    static let description = IntentDescription("Wake BOT and start a voice conversation.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchSignal.shared.request()
        return .result()
    }
}

struct BOTShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToBOTIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Hey \(.applicationName)",
                "Wake up \(.applicationName)",
                "Open \(.applicationName)",
                "Ask \(.applicationName)",
            ],
            shortTitle: "Talk to BOT",
            systemImageName: "mic.fill"
        )
    }
}
