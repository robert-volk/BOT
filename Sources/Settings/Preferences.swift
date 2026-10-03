import SwiftUI

// MARK: - Option enums (the "design options" the Settings screen exposes)

enum AccentPreset: String, Codable, CaseIterable, Identifiable {
    case sky, cobalt, electric, navy, ice, cyan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sky: return "Sky"
        case .cobalt: return "Cobalt"
        case .electric: return "Electric"
        case .navy: return "Navy"
        case .ice: return "Ice"
        case .cyan: return "Cyan"
        }
    }
    var color: Color {
        switch self {
        case .sky: return Color(red: 0.22, green: 0.66, blue: 0.96)
        case .cobalt: return Color(red: 0.12, green: 0.36, blue: 0.85)
        case .electric: return Color(red: 0.16, green: 0.47, blue: 1.00)
        case .navy: return Color(red: 0.11, green: 0.23, blue: 0.48)
        case .ice: return Color(red: 0.49, green: 0.77, blue: 1.00)
        case .cyan: return Color(red: 0.13, green: 0.78, blue: 0.88)
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case solid, gradient, grid, glow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        case .grid: return "Grid"
        case .glow: return "Glow"
        }
    }
}

enum FontStyle: String, Codable, CaseIterable, Identifiable {
    case rounded, standard, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rounded: return "Rounded"
        case .standard: return "Standard"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .standard: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

enum RobotStyle: String, Codable, CaseIterable, Identifiable {
    case classic, inverted, outline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .inverted: return "Inverted"
        case .outline: return "Outline"
        }
    }
}

enum EyeStyle: String, Codable, CaseIterable, Identifiable {
    case round, square, pill
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MouthStyle: String, Codable, CaseIterable, Identifiable {
    case bars, smile
    var id: String { rawValue }
    var title: String { self == .bars ? "Equalizer" : "Smile" }
}

enum ReplyLength: String, Codable, CaseIterable, Identifiable {
    case brief, normal, detailed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var maxTokens: Int {
        switch self {
        case .brief: return 90
        case .normal: return 170
        case .detailed: return 320
        }
    }
    var instruction: String {
        switch self {
        case .brief: return "Keep replies to one or two short sentences."
        case .normal: return "Keep replies to two or three short sentences."
        case .detailed: return "You may give fuller answers of up to about six sentences when the question needs it."
        }
    }
}

enum Personality: String, Codable, CaseIterable, Identifiable {
    case warm, upbeat, calm, witty
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var instruction: String {
        switch self {
        case .warm: return "You are warm, friendly and genuinely curious about the person, like a close friend."
        case .upbeat: return "You are upbeat, energetic and encouraging."
        case .calm: return "You are calm, gentle and thoughtful, never rushed."
        case .witty: return "You are quick-witted with a light, playful sense of humor, but never at the person's expense."
        }
    }
}

enum BrainChoice: String, Codable, CaseIterable, Identifiable {
    case auto, apple, claude, basic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .apple: return "On-device (Apple Intelligence)"
        case .claude: return "Claude Haiku (needs API key)"
        case .basic: return "Basic (no AI)"
        }
    }
}

// MARK: - Preferences (persisted as one JSON blob)

struct Preferences: Codable, Equatable {
    // Look & feel
    var accent: AccentPreset = .sky
    var appearance: AppearanceMode = .system
    var background: BackgroundStyle = .glow
    var font: FontStyle = .rounded
    var robotStyle: RobotStyle = .classic
    var eyes: EyeStyle = .round
    var mouth: MouthStyle = .bars
    var robotScale: Double = 1.0
    var animationLevel: Double = 0.8
    var showCaptions: Bool = true
    var captionSize: Double = 20
    var haptics: Bool = true

    // Voice
    var voiceID: String? = nil
    var rate: Double = 0.52
    var pitch: Double = 1.05

    // Conversation
    var botName: String = "BOT"
    var handsFree: Bool = true
    var silenceDelay: Double = 1.0
    var replyLength: ReplyLength = .brief
    var personality: Personality = .warm
    var learnAboutMe: Bool = true

    // Brain
    var brain: BrainChoice = .auto
}

@MainActor
final class AppSettings: ObservableObject {
    private static let key = "bot.preferences.v1"

    @Published var prefs: Preferences {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode(Preferences.self, from: data) {
            prefs = p
        } else {
            prefs = Preferences()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // One-tap look presets.
    struct Preset: Identifiable {
        let id: String
        let apply: (inout Preferences) -> Void
    }

    static let presets: [Preset] = [
        Preset(id: "Classic") { p in
            p.accent = .sky; p.appearance = .system; p.background = .glow; p.font = .rounded
            p.robotStyle = .classic; p.eyes = .round; p.mouth = .bars
        },
        Preset(id: "Midnight") { p in
            p.accent = .electric; p.appearance = .dark; p.background = .gradient; p.font = .rounded
            p.robotStyle = .inverted; p.eyes = .pill; p.mouth = .bars
        },
        Preset(id: "Frost") { p in
            p.accent = .ice; p.appearance = .light; p.background = .solid; p.font = .standard
            p.robotStyle = .classic; p.eyes = .round; p.mouth = .smile
        },
        Preset(id: "Neon") { p in
            p.accent = .cyan; p.appearance = .dark; p.background = .grid; p.font = .mono
            p.robotStyle = .outline; p.eyes = .square; p.mouth = .bars
        },
        Preset(id: "Studio") { p in
            p.accent = .navy; p.appearance = .light; p.background = .gradient; p.font = .serif
            p.robotStyle = .inverted; p.eyes = .round; p.mouth = .smile
        },
    ]

    func apply(_ preset: Preset) {
        var p = prefs
        preset.apply(&p)
        prefs = p
    }
}

// MARK: - Resolved theme (depends on the system color scheme)

struct Theme {
    let accent: Color
    let background: Color
    let backgroundAlt: Color
    let surface: Color
    let text: Color
    let subtext: Color
    let isDark: Bool
    let fontDesign: Font.Design

    init(prefs: Preferences, scheme: ColorScheme) {
        isDark = scheme == .dark
        accent = prefs.accent.color
        fontDesign = prefs.font.design
        if isDark {
            background = Color(red: 0.04, green: 0.08, blue: 0.18)
            backgroundAlt = Color(red: 0.07, green: 0.15, blue: 0.33)
            surface = Color.white.opacity(0.08)
            text = .white
            subtext = Color.white.opacity(0.62)
        } else {
            background = Color(red: 0.96, green: 0.98, blue: 1.0)
            backgroundAlt = Color(red: 0.82, green: 0.90, blue: 1.0)
            surface = Color(red: 0.10, green: 0.30, blue: 0.70).opacity(0.07)
            text = Color(red: 0.06, green: 0.12, blue: 0.28)
            subtext = Color(red: 0.06, green: 0.12, blue: 0.28).opacity(0.58)
        }
    }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: fontDesign)
    }
}
