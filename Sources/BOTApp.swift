import SwiftUI

@main
struct BOTApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var facts: FactStore
    @StateObject private var engine: ConversationEngine
    @StateObject private var reminders: ReminderCenter

    init() {
        let s = AppSettings()
        let f = FactStore()
        let r = ReminderCenter()
        _settings = StateObject(wrappedValue: s)
        _facts = StateObject(wrappedValue: f)
        _reminders = StateObject(wrappedValue: r)
        _engine = StateObject(wrappedValue: ConversationEngine(settings: s, facts: f, reminders: r))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(facts)
                .environmentObject(engine)
                .environmentObject(reminders)
                .preferredColorScheme(settings.prefs.appearance.scheme)
        }
    }
}
