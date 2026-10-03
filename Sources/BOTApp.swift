import SwiftUI

@main
struct BOTApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var facts: FactStore
    @StateObject private var engine: ConversationEngine

    init() {
        let s = AppSettings()
        let f = FactStore()
        _settings = StateObject(wrappedValue: s)
        _facts = StateObject(wrappedValue: f)
        _engine = StateObject(wrappedValue: ConversationEngine(settings: s, facts: f))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(facts)
                .environmentObject(engine)
                .preferredColorScheme(settings.prefs.appearance.scheme)
        }
    }
}
