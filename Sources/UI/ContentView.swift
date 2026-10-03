import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: ConversationEngine
    @EnvironmentObject var facts: FactStore
    @EnvironmentObject var reminders: ReminderCenter
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var showMemory = false
    @State private var showTranscript = false
    @State private var showReminders = false

    private var prefs: Preferences { settings.prefs }
    private var theme: Theme { Theme(prefs: prefs, scheme: scheme) }

    var body: some View {
        ZStack {
            BackgroundView(theme: theme, style: prefs.background)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                robot
                statusBlock
                captions
                Spacer(minLength: 8)
                controls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if let learned = engine.learnedToast {
                VStack {
                    learnedBadge(learned)
                    Spacer()
                }
                .padding(.top, 58)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: engine.learnedToast)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings).environmentObject(engine).environmentObject(facts)
                .preferredColorScheme(prefs.appearance.scheme)
        }
        .sheet(isPresented: $showMemory) {
            NavigationStack { MemoryView() }
                .environmentObject(settings).environmentObject(facts)
                .preferredColorScheme(prefs.appearance.scheme)
        }
        .sheet(isPresented: $showReminders) {
            RemindersView().environmentObject(reminders)
                .preferredColorScheme(prefs.appearance.scheme)
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptView(theme: theme).environmentObject(engine)
                .preferredColorScheme(prefs.appearance.scheme)
        }
        .alert("Microphone & Speech Access", isPresented: $engine.permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BOT needs the microphone and speech recognition to hear you. Turn both on in Settings.")
        }
        .onChange(of: scenePhase) { _, new in
            if new != .active { engine.end() }
        }
        .onChange(of: engine.active) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onChange(of: prefs.brain) { _, _ in engine.refreshBrain() }
        .onChange(of: prefs.webSearch) { _, _ in engine.refreshBrain() }
        .tint(theme.accent)
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            iconButton("slider.horizontal.3") { showSettings = true }
            Spacer()
            Text(prefs.botName)
                .font(theme.font(20, .bold))
                .tracking(2)
                .foregroundStyle(theme.text)
            Spacer()
            iconButton("text.bubble") { showTranscript = true }
            ZStack(alignment: .topTrailing) {
                iconButton("bell.fill") { showReminders = true }
                if !reminders.items.isEmpty {
                    Circle().fill(theme.accent).frame(width: 10, height: 10).offset(x: -3, y: 3)
                }
            }
            ZStack(alignment: .topTrailing) {
                iconButton("brain.head.profile") { showMemory = true }
                if !facts.facts.isEmpty {
                    Text("\(facts.facts.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.accent, in: Capsule())
                        .offset(x: 4, y: -2)
                }
            }
        }
        .padding(.top, 4)
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: 42, height: 42)
                .background(theme.surface, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var robot: some View {
        RobotView(style: prefs.robotStyle, eyes: prefs.eyes, mouth: prefs.mouth,
                  accent: theme.accent, isDark: theme.isDark,
                  phase: engine.phase, level: engine.micLevel,
                  animation: prefs.animationLevel, size: 270 * prefs.robotScale)
            .frame(height: 290 * prefs.robotScale)
            .contentShape(Rectangle())
            .onTapGesture { engine.primaryTap() }
            .accessibilityElement()
            .accessibilityLabel("\(prefs.botName) robot")
            .accessibilityHint("Double tap to talk")
            .accessibilityAddTraits(.isButton)
    }

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(statusText)
                .font(theme.font(17, .semibold))
                .foregroundStyle(theme.text)
            HStack(spacing: 6) {
                Image(systemName: engine.brainName == "Basic mode" ? "exclamationmark.triangle.fill" : "bolt.fill")
                Text(engine.brainName)
            }
            .font(theme.font(12, .medium))
            .foregroundStyle(theme.subtext)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(theme.surface, in: Capsule())

            if let note = engine.brainNote {
                Text(note + " Open Settings → Brain.")
                    .font(theme.font(12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if let err = engine.errorNote {
                Text(err)
                    .font(theme.font(12))
                    .foregroundStyle(.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.top, 6)
    }

    private var statusText: String {
        switch engine.phase {
        case .idle: return "Tap to talk"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        }
    }

    private var captionText: String {
        switch engine.phase {
        case .listening: return engine.partialHeard
        case .thinking: return engine.turns.last(where: { $0.role == .user })?.text ?? ""
        case .speaking: return engine.liveReply
        case .idle: return engine.turns.last(where: { $0.role == .assistant })?.text ?? "Say hello. I'm all ears."
        }
    }

    @ViewBuilder
    private var captions: some View {
        if prefs.showCaptions {
            ScrollView(showsIndicators: false) {
                Text(captionText)
                    .font(theme.font(prefs.captionSize, .medium))
                    .foregroundStyle(engine.phase == .thinking || engine.phase == .listening ? theme.subtext : theme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 70, maxHeight: 150)
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.2), value: captionText)
        } else {
            Spacer().frame(height: 30)
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            // End conversation
            Button { engine.end() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.text)
                    .frame(width: 50, height: 50)
                    .background(theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(engine.active ? 1 : 0.3)
            .disabled(!engine.active)

            // Main talk button
            Button { engine.primaryTap() } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [theme.accent, theme.accent.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 84, height: 84)
                        .shadow(color: theme.accent.opacity(0.5), radius: 14, y: 6)
                    if engine.phase == .listening {
                        Circle()
                            .stroke(.white.opacity(0.5), lineWidth: 3)
                            .frame(width: 84 + CGFloat(engine.micLevel) * 28, height: 84 + CGFloat(engine.micLevel) * 28)
                            .animation(.easeOut(duration: 0.1), value: engine.micLevel)
                    }
                    Image(systemName: mainIcon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)

            // Hands-free toggle
            Button { settings.prefs.handsFree.toggle() } label: {
                Image(systemName: prefs.handsFree ? "ear.fill" : "hand.tap.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(prefs.handsFree ? .white : theme.text)
                    .frame(width: 50, height: 50)
                    .background(prefs.handsFree ? theme.accent : theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(prefs.handsFree ? "Hands-free on" : "Hands-free off")
        }
        .padding(.top, 4)
    }

    private var mainIcon: String {
        switch engine.phase {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "hand.raised.fill"
        }
    }

    private func learnedBadge(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
            Text("Learned: \(text)").lineLimit(2)
        }
        .font(theme.font(13, .medium))
        .foregroundStyle(theme.text)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(theme.accent.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 24)
    }
}
