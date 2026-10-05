import Foundation
import CoreLocation
import Vision
import UIKit

// MARK: - Saved items

struct MeetingNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var minutes: Int
    var summary: String
    var actions: [String]
    var transcript: String
    var title: String? = nil
}

struct JournalEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var text: String
    var mood: String?
}

struct ParkingSpot: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var place: String
    var note: String
    var date: Date
}

// MARK: - Voice commands

enum LifeIntent {
    case startMeeting
    case startJournal
    case journalNow(String)
    case reflectWeek
    case lastMeeting
    case parkHere(note: String)
    case whereParked
    case readText

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func parse(_ raw: String) -> LifeIntent? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))

        if match(#"\b(?:start|begin|take|record)\b.{0,20}\bmeeting (?:notes|minutes)\b|\b(?:take|start|record)\b.{0,12}\bnotes?\b.{0,20}\b(?:this |the |my )?(?:meeting|call)\b|\btranscribe (?:this|the|my) (?:meeting|call)\b"#, t) != nil {
            return .startMeeting
        }
        if let g = match(#"^(?:journal|dear diary)[:,]?\s+(.{8,})$"#, t) { return .journalNow(g[1]) }
        if match(#"^(?:start|begin|open|new)\b.{0,15}\bjournal\b|^(?:let'?s )?journal$|^dear diary$|^i want to journal"#, t) != nil {
            return .startJournal
        }
        if match(#"\b(?:reflect on|how (?:was|has been|did) my week|summarize my (?:week|journal)|journal (?:summary|recap)|what did i write(?: this week)?)\b"#, t) != nil {
            return .reflectWeek
        }
        if match(#"\b(?:action items|my meeting (?:notes|summary)|last meeting)\b"#, t) != nil { return .lastMeeting }

        if match(#"\bwhere(?:'s| is| did i)\b.{0,15}\b(?:park|parked|my car)\b|\bfind my car\b"#, t) != nil { return .whereParked }
        if match(#"\b(?:remember|save|mark|log|note)\b.{0,25}\b(?:park(?:ed|ing)|my car)\b|^i(?:'m| am| just)? (?:just )?parked\b|\bi parked (?:here|on|in|at|near)\b"#, t) != nil {
            let note = match(#"(?:\bon|\bin|\bat|\bnear|\bby)\s+((?:level|floor|row|section|space|spot|lot|zone|aisle)?\s*[A-Za-z0-9 ]{1,30})$"#, t)?[1]
                .trimmingCharacters(in: .whitespaces) ?? ""
            return .parkHere(note: note == "here" ? "" : note)
        }
        if match(#"\b(?:read (?:this|that|it)(?: to me| aloud| out loud)?|what does (?:this|it|that) say|scan (?:this|the text)|read (?:the|this) (?:text|sign|label|letter|menu))\b"#, t) != nil {
            return .readText
        }
        return nil
    }
}

// MARK: - Meeting summaries (on-device AI only)

enum MeetingSummarizer {
    struct Result {
        var summary: String
        var actions: [String]
    }

    private static let system = "You summarize meeting transcripts. Reply in exactly this format: one line starting with SUMMARY: containing at most two sentences, then one line starting with ACTION: for each concrete action item (who does what, and by when if it was said). If there are no action items, write no ACTION lines. Plain text only."

    static func summarize(_ transcript: String, brain: Brain?) async -> Result {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 40 else {
            return Result(summary: clean.isEmpty ? "I didn't catch anything." : clean, actions: [])
        }
        guard let brain else { return heuristic(clean) }

        var summaries: [String] = []
        var actions: [String] = []
        for chunk in split(clean, size: 2800) {
            guard let out = try? await brain.complete(system: system, prompt: chunk, maxTokens: 240) else { continue }
            var gotSummary = false
            for raw in out.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let upper = line.uppercased()
                if upper.hasPrefix("SUMMARY:") {
                    summaries.append(String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces))
                    gotSummary = true
                } else if upper.hasPrefix("ACTION:") {
                    let a = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    if !a.isEmpty { actions.append(a) }
                } else if !gotSummary, !line.isEmpty, !upper.hasPrefix("NONE") {
                    summaries.append(line)
                    gotSummary = true
                }
            }
        }
        guard !summaries.isEmpty else { return heuristic(clean) }

        var summary = summaries.joined(separator: " ")
        if summaries.count > 1,
           let combined = try? await brain.complete(system: "Combine these partial meeting summaries into one summary of at most three sentences. Plain text only.",
                                                    prompt: summary, maxTokens: 170) {
            let c = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty { summary = c }
        }
        var seen = Set<String>()
        let unique = actions.filter { seen.insert($0.lowercased()).inserted }
        return Result(summary: summary, actions: Array(unique.prefix(8)))
    }

    private static func split(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in text.components(separatedBy: ". ") {
            if current.count + sentence.count > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += sentence + ". "
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Without on-device AI: the opening sentences plus any sentence that sounds like a commitment.
    private static func heuristic(_ text: String) -> Result {
        let sentences = text.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 12 }
        let pattern = #"\b(?:i'?ll|i will|we'?ll|we will|we need to|you need to|action item|follow up|let'?s|deadline|by (?:monday|tuesday|wednesday|thursday|friday|tomorrow|end of day|next week))\b"#
        let actions = sentences.filter { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        let opening = sentences.prefix(2).joined(separator: ". ")
        return Result(summary: "On-device AI isn't available, so these are the opening lines: " + opening + ".",
                      actions: Array(actions.prefix(8)))
    }
}

// MARK: - Read text aloud (Apple's on-device text recognition)

enum TextReader {
    /// Text in an image, top to bottom. Synchronous: call it from a background task.
    static func recognize(_ cg: CGImage, orientation: CGImagePropertyOrientation) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? []).sorted { a, b in
            if abs(a.boundingBox.maxY - b.boundingBox.maxY) > 0.015 { return a.boundingBox.maxY > b.boundingBox.maxY }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    static func read(_ jpeg: Data) async -> String {
        guard let image = UIImage(data: jpeg), let cg = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).sorted { a, b in
                if abs(a.boundingBox.maxY - b.boundingBox.maxY) > 0.015 { return a.boundingBox.maxY > b.boundingBox.maxY }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }.value
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
