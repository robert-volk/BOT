import SwiftUI

@main
struct BOTApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var facts: FactStore
    @StateObject private var engine: ConversationEngine
    @StateObject private var reminders: ReminderCenter
    @StateObject private var calendar: CalendarCenter

    init() {
        let s = AppSettings()
        let f = FactStore()
        let r = ReminderCenter()
        let c = CalendarCenter(reminders: r)
        _settings = StateObject(wrappedValue: s)
        _facts = StateObject(wrappedValue: f)
        _reminders = StateObject(wrappedValue: r)
        _calendar = StateObject(wrappedValue: c)
        _engine = StateObject(wrappedValue: ConversationEngine(settings: s, facts: f, reminders: r, calendar: c))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(facts)
                .environmentObject(engine)
                .environmentObject(reminders)
                .environmentObject(calendar)
                .preferredColorScheme(settings.prefs.appearance.scheme)
        }
    }
}
