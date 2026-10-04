import SwiftUI

@main
struct BOTApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var facts: FactStore
    @StateObject private var engine: ConversationEngine
    @StateObject private var reminders: ReminderCenter
    @StateObject private var calendar: CalendarCenter
    @StateObject private var lists: ListStore
    @StateObject private var emailStore: EmailStore

    init() {
        let s = AppSettings()
        let f = FactStore()
        let r = ReminderCenter()
        r.backgroundSpeech = s.prefs.speakInBackground
        r.scheduleBriefing(enabled: s.prefs.briefingEnabled, minutes: s.prefs.briefingMinutes)
        let c = CalendarCenter(reminders: r)
        let l = ListStore()
        let em = EmailStore()
        _settings = StateObject(wrappedValue: s)
        _facts = StateObject(wrappedValue: f)
        _reminders = StateObject(wrappedValue: r)
        _calendar = StateObject(wrappedValue: c)
        _lists = StateObject(wrappedValue: l)
        _emailStore = StateObject(wrappedValue: em)
        _engine = StateObject(wrappedValue: ConversationEngine(settings: s, facts: f, reminders: r, calendar: c, lists: l, email: em))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(facts)
                .environmentObject(engine)
                .environmentObject(reminders)
                .environmentObject(calendar)
                .environmentObject(lists)
                .environmentObject(emailStore)
                .preferredColorScheme(settings.prefs.appearance.scheme)
        }
    }
}
