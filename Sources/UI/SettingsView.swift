import SwiftUI

/// All the knobs for fine-tuning BOT's look, voice, personality and brain.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: ConversationEngine
    @EnvironmentObject var facts: FactStore
    @EnvironmentObject var calendar: CalendarCenter
    @EnvironmentObject var reminders: ReminderCenter
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var previewPhase: Phase = .idle
    @State private var keyField = ""
    @State private var braveField = ""
    @State private var testReport: [String] = []
    @State private var testing = false
    @State private var voices: [Speaker.VoiceInfo] = []

    private var theme: Theme { Theme(prefs: settings.prefs, scheme: scheme) }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                presetsSection
                colorSection
                robotSection
                captionSection
                voiceSection
                conversationSection
                brainSection
                searchSection
                siriSection
                calendarSection
                alertTestSection
                memorySection
                resetSection
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { voices = Speaker.femaleAmericanVoices() }
            .onChange(of: settings.prefs.brain) { _, _ in engine.refreshBrain() }
            .onChange(of: settings.prefs.calendarAlerts) { _, on in
                Task {
                    if on, !(await calendar.requestAccess()) { settings.prefs.calendarAlerts = false; return }
                    await calendar.sync(with: settings.prefs)
                }
            }
            .onChange(of: settings.prefs.calendarLead) { _, _ in Task { await calendar.sync(with: settings.prefs) } }
        }
        .tint(theme.accent)
    }

    // MARK: Sections

    private var previewSection: some View {
        Section {
            ZStack {
                BackgroundView(theme: theme, style: settings.prefs.background)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                RobotView(style: settings.prefs.robotStyle, eyes: settings.prefs.eyes, mouth: settings.prefs.mouth,
                          accent: theme.accent, isDark: theme.isDark, phase: previewPhase,
                          level: previewPhase == .listening ? 0.5 : 0,
                          animation: settings.prefs.animationLevel, size: 190)
                    .padding(.vertical, 10)
            }
            .frame(height: 220)
            .listRowInsets(EdgeInsets())

            Picker("Preview state", selection: $previewPhase) {
                Text("Idle").tag(Phase.idle)
                Text("Listening").tag(Phase.listening)
                Text("Thinking").tag(Phase.thinking)
                Text("Speaking").tag(Phase.speaking)
            }
            .pickerStyle(.segmented)
        } header: { Text("Preview") }
    }

    private var presetsSection: some View {
        Section("Quick looks") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AppSettings.presets) { preset in
                        Button(preset.id) { settings.apply(preset) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var colorSection: some View {
        Section("Color & style") {
            HStack(spacing: 14) {
                ForEach(AccentPreset.allCases) { a in
                    Button { settings.prefs.accent = a } label: {
                        Circle().fill(a.color).frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.primary.opacity(settings.prefs.accent == a ? 0.9 : 0), lineWidth: 3).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.title)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            Picker("Appearance", selection: $settings.prefs.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Background", selection: $settings.prefs.background) {
                ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Text font", selection: $settings.prefs.font) {
                ForEach(FontStyle.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var robotSection: some View {
        Section("Robot") {
            Picker("Style", selection: $settings.prefs.robotStyle) {
                ForEach(RobotStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Eyes", selection: $settings.prefs.eyes) {
                ForEach(EyeStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Mouth", selection: $settings.prefs.mouth) {
                ForEach(MouthStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            sliderRow("Size", value: $settings.prefs.robotScale, range: 0.7...1.2, format: "%.2f×")
            sliderRow("Animation", value: $settings.prefs.animationLevel, range: 0...1, format: "%.0f%%", scale: 100)
            Toggle("Haptics", isOn: $settings.prefs.haptics)
        }
    }

    private var captionSection: some View {
        Section("Captions") {
            Toggle("Show captions", isOn: $settings.prefs.showCaptions)
            if settings.prefs.showCaptions {
                sliderRow("Text size", value: $settings.prefs.captionSize, range: 14...34, format: "%.0f pt")
            }
        }
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { settings.prefs.voiceID ?? "" },
                set: { settings.prefs.voiceID = $0.isEmpty ? nil : $0 })
    }

    private var voiceSection: some View {
        Section {
            Picker("Voice", selection: voiceBinding) {
                Text("Best available (auto)").tag("")
                ForEach(voices) { v in Text("\(v.name) · \(v.quality)").tag(v.id) }
            }
            sliderRow("Speed", value: $settings.prefs.rate, range: 0.3...0.65, format: "%.2f")
            sliderRow("Pitch", value: $settings.prefs.pitch, range: 0.8...1.3, format: "%.2f")
            Button {
                engine.previewVoice()
            } label: {
                Label("Preview voice", systemImage: "speaker.wave.2.fill")
            }
        } header: { Text("Voice") } footer: {
            Text("BOT's voice is Apple's free on-device voice, so it costs nothing and works offline. For a more natural, human sound, download an Enhanced or Premium voice: iOS Settings → Accessibility → Spoken Content → Voices → English (United States) → Ava or Samantha (Premium/Enhanced). It will then show up here and be picked automatically.")
        }
    }

    private var conversationSection: some View {
        Section("Conversation") {
            HStack {
                Text("Name")
                TextField("BOT", text: $settings.prefs.botName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            Toggle("Hands-free (keep listening)", isOn: $settings.prefs.handsFree)
            sliderRow("Pause before reply", value: $settings.prefs.silenceDelay, range: 0.6...2.0, format: "%.1f s")
            Picker("Reply length", selection: $settings.prefs.replyLength) {
                ForEach(ReplyLength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Personality", selection: $settings.prefs.personality) {
                ForEach(Personality.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var brainSection: some View {
        Section {
            Picker("Brain", selection: $settings.prefs.brain) {
                ForEach(BrainChoice.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Now using", value: engine.brainName)
            LabeledContent("Apple on-device") {
                Text(BrainFactory.appleUnavailableReason() ?? "Ready")
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(BrainFactory.appleUnavailableReason() == nil ? .green : .orange)
            }
            if engine.hasClaudeKey {
                LabeledContent("Claude API key", value: "Saved")
                Button("Remove key", role: .destructive) { engine.setClaudeKey(""); keyField = "" }
            } else {
                SecureField("Claude API key (optional)", text: $keyField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") { engine.setClaudeKey(keyField); keyField = "" }
                    .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Brain") } footer: {
            Text("Automatic uses Apple's on-device model (free, private, very fast; needs an iPhone 15 Pro or newer with Apple Intelligence on). If that's not available it uses Claude Haiku when you've added a key (fast, but billed by Anthropic), otherwise Basic mode. Only the AI's thinking can use a key; BOT's voice never does.")
        }
    }

    private var searchSection: some View {
        Section {
            Toggle("Web search (news, facts, weather)", isOn: $settings.prefs.webSearch)
            if engine.hasBraveKey {
                LabeledContent("Brave Search key", value: "Saved")
                Button("Remove key", role: .destructive) { engine.setBraveKey(""); braveField = "" }
            } else {
                SecureField("Brave Search key (optional)", text: $braveField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") { engine.setBraveKey(braveField); braveField = "" }
                    .disabled(braveField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Search") } footer: {
            Text("With a Claude key, Claude searches the live web itself (Anthropic bills a small fee per search). Otherwise BOT searches DuckDuckGo (free) and reads the top pages. A Brave Search key from brave.com/search/api makes that more reliable. Only your search words go to the search provider.")
        }
    }

    private var siriSection: some View {
        Section {
            Label("Say “Hey Siri, talk to BOT”", systemImage: "mic.fill")
        } header: { Text("Wake up") } footer: {
            Text("BOT opens and starts listening. Other phrases that work: “Hey Siri, wake up BOT” or “Hey Siri, ask BOT”. If Siri doesn't recognize it, open BOT once and give Siri a minute to learn it. You can also run it from the Shortcuts app (search “Talk to BOT”) and bind it to the Action Button (iOS Settings, Action Button, Shortcut) or Back Tap (Accessibility, Touch, Back Tap). Say “goodbye” to end a conversation.")
        }
    }

    private var calendarSection: some View {
        Section {
            Toggle("Meeting alerts", isOn: $settings.prefs.calendarAlerts)
            if settings.prefs.calendarAlerts {
                Picker("Alert me", selection: $settings.prefs.calendarLead) {
                    Text("When it starts").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                }
            }
            Toggle("Let Claude see my schedule", isOn: $settings.prefs.calendarToClaude)
        } header: { Text("Calendar") } footer: {
            Text("BOT reads your calendar but never changes it. Alerts show a banner and speak the meeting aloud, and are scheduled for the next 3 days each time you open BOT, so open it every few days and after your schedule changes. You can ask “What’s on my calendar today?” or “When’s my next meeting?”. The on-device AI always sees your next two days; Claude only does if you turn on the last switch, because that sends event titles to Anthropic.")
        }
    }

    private var alertTestSection: some View {
        Section {
            Button {
                testing = true
                Task {
                    testReport = await reminders.runAlertTest(voiceID: settings.prefs.voiceID,
                                                              rate: Float(settings.prefs.rate),
                                                              pitch: Float(settings.prefs.pitch))
                    testing = false
                }
            } label: {
                Label(testing ? "Testing..." : "Test spoken alert", systemImage: "bell.and.waves.left.and.right")
            }
            .disabled(testing)
            ForEach(testReport, id: \.self) { line in
                Text(line).font(.footnote)
                    .foregroundStyle(line.hasPrefix("FAIL") || line.hasPrefix("FIX") ? Color.red : Color.secondary)
            }
        } header: { Text("Reminder sound") } footer: {
            Text("Checks that BOT can record its voice for lock-screen alerts, plays it, then sends a test alert in 10 seconds.")
        }
    }

    private var memorySection: some View {
        Section {
            Toggle("Learn about me", isOn: $settings.prefs.learnAboutMe)
            NavigationLink {
                MemoryView()
            } label: {
                LabeledContent("What BOT knows", value: "\(facts.facts.count) facts")
            }
        } header: { Text("Memory") } footer: {
            Text("Facts are saved only on this iPhone. You can also say \"remember that…\", \"forget that…\" or \"forget everything about me\".")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset look to defaults", role: .destructive) {
                var p = Preferences()
                // Keep non-visual choices.
                let old = settings.prefs
                p.voiceID = old.voiceID; p.rate = old.rate; p.pitch = old.pitch
                p.botName = old.botName; p.handsFree = old.handsFree; p.silenceDelay = old.silenceDelay
                p.replyLength = old.replyLength; p.personality = old.personality
                p.learnAboutMe = old.learnAboutMe; p.brain = old.brain; p.webSearch = old.webSearch
                settings.prefs = p
            }
        }
    }

    // MARK: Helpers

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}
