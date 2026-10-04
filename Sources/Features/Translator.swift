import Foundation
import AVFoundation

/// "How do you say where is the bathroom in Spanish?" / "Translate good morning into French."
/// The AI brain does the translating; BOT then speaks the result with a native-language voice.
enum Translator {
    struct Request {
        var text: String
        var language: String   // display name, e.g. "Spanish"
        var code: String       // BCP-47, e.g. "es-ES"
    }

    static let languages: [String: String] = [
        "spanish": "es-ES", "french": "fr-FR", "german": "de-DE", "italian": "it-IT", "portuguese": "pt-BR",
        "japanese": "ja-JP", "chinese": "zh-CN", "mandarin": "zh-CN", "korean": "ko-KR", "hindi": "hi-IN",
        "arabic": "ar-SA", "russian": "ru-RU", "dutch": "nl-NL", "swedish": "sv-SE", "polish": "pl-PL",
        "turkish": "tr-TR", "greek": "el-GR", "hebrew": "he-IL", "vietnamese": "vi-VN", "thai": "th-TH",
        "indonesian": "id-ID", "norwegian": "nb-NO", "danish": "da-DK", "finnish": "fi-FI", "czech": "cs-CZ",
        "ukrainian": "uk-UA", "romanian": "ro-RO", "hungarian": "hu-HU",
    ]

    static func parse(_ raw: String) -> Request? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\"'"))
        let patterns = [
            #"^(?:please )?(?:how (?:do|would|can) (?:you|i) say|how to say|what'?s|what is|what would be)\s+(.+?)\s+in\s+([A-Za-z]+)$"#,
            #"^(?:please )?(?:translate|say)\s+(.+?)\s+(?:in|into|to)\s+([A-Za-z]+)$"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let a = Range(m.range(at: 1), in: t), let b = Range(m.range(at: 2), in: t) else { continue }
            let lang = t[b].lowercased()
            guard let code = languages[lang] else { continue }
            let phrase = t[a].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if phrase.isEmpty { continue }
            return Request(text: phrase, language: lang.capitalized, code: code)
        }
        return nil
    }

    static let systemPrompt = "You are a precise translator. Translate the user's text into the requested language. Output ONLY the translation: no quotes, no notes, no transliteration."

    static func prompt(_ r: Request) -> String {
        "Translate into \(r.language): \(r.text)"
    }

    /// Best installed voice for a language (any region of it), preferring higher quality and female voices.
    static func voice(for code: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(code.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let best = candidates.max { a, b in
            func score(_ v: AVSpeechSynthesisVoice) -> Int {
                var s = v.quality == .premium ? 30 : (v.quality == .enhanced ? 20 : 10)
                if v.language == code { s += 5 }
                if v.gender == .female { s += 2 }
                return s
            }
            return score(a) < score(b)
        }
        return best ?? AVSpeechSynthesisVoice(language: code)
    }
}
