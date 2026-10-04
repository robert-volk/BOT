import Foundation

/// Understands "remind me to call Mom at 5", "set a timer for 10 minutes", "what are my reminders", etc.
/// Handled locally and instantly, with no AI needed.
enum ReminderParser {
    struct Parsed {
        var task: String?
        var date: Date?
        var repeatRule: String?
    }

    /// How a reminder repeats. Stored on a reminder as "daily", "weekdays", "weekly:N" (1 = Sunday) or "monthly:D".
    enum RepeatKind {
        case daily, weekdays, weekly(Int), monthly(Int)

        init?(_ rule: String) {
            if rule == "daily" { self = .daily }
            else if rule == "weekdays" { self = .weekdays }
            else if rule.hasPrefix("weekly:"), let d = Int(rule.dropFirst(7)), (1...7).contains(d) { self = .weekly(d) }
            else if rule.hasPrefix("monthly:"), let d = Int(rule.dropFirst(8)), (1...31).contains(d) { self = .monthly(d) }
            else { return nil }
        }
    }

    /// The next time a repeating reminder fires after `after`.
    static func nextOccurrence(_ kind: RepeatKind, hour: Int, minute: Int, after: Date) -> Date? {
        let cal = Calendar.current
        var c = DateComponents()
        c.hour = hour
        c.minute = minute
        switch kind {
        case .daily:
            return cal.nextDate(after: after, matching: c, matchingPolicy: .nextTime)
        case .weekdays:
            return (2...6).compactMap { d -> Date? in
                var w = c
                w.weekday = d
                return cal.nextDate(after: after, matching: w, matchingPolicy: .nextTime)
            }.min()
        case .weekly(let d):
            c.weekday = d
            return cal.nextDate(after: after, matching: c, matchingPolicy: .nextTime)
        case .monthly(let day):
            c.day = day
            return cal.nextDate(after: after, matching: c, matchingPolicy: .nextTime)
        }
    }

    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Finds and removes a repeat phrase ("every weekday", "daily", "every Monday"...). Returns the rule and a default hour.
    private static func extractRepeat(_ text: inout String) -> (rule: String, defaultHour: Int?)? {
        func take(_ pattern: String) -> String? {
            guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let found = String(text[r])
            text.removeSubrange(r)
            return found.lowercased()
        }
        if take(#"\bevery\s+(?:week ?days?|work ?days?)\b|\b(?:on\s+)?week ?days\b"#) != nil { return ("weekdays", nil) }
        let dayList = weekdayNames.joined(separator: "|")
        if let f = take(#"\b(?:every|each|on)\s+(?:"# + dayList + #")s?\b"#) {
            if let i = weekdayNames.firstIndex(where: { f.contains($0) }) { return ("weekly:\(i + 1)", nil) }
        }
        if let f = take(#"\b(?:every|each)\s+(?:day|morning|afternoon|evening|night)\b|\bdaily\b"#) {
            if f.contains("morning") { return ("daily", 8) }
            if f.contains("afternoon") { return ("daily", 15) }
            if f.contains("evening") { return ("daily", 18) }
            if f.contains("night") { return ("daily", 21) }
            return ("daily", nil)
        }
        if take(#"\bevery\s+week\b|\bweekly\b"#) != nil { return ("weekly:0", nil) }
        if take(#"\bevery\s+month\b|\bmonthly\b"#) != nil { return ("monthly:0", nil) }
        return nil
    }

    /// Resolves placeholder rules ("weekly:0") from the chosen date and moves it to the next real occurrence.
    static func finalizeRepeat(rule: String?, date: Date) -> (rule: String?, date: Date) {
        guard var r = rule else { return (nil, date) }
        let cal = Calendar.current
        if r == "weekly:0" { r = "weekly:\(cal.component(.weekday, from: date))" }
        if r == "monthly:0" { r = "monthly:\(cal.component(.day, from: date))" }
        guard let kind = RepeatKind(r) else { return (nil, date) }
        let next = nextOccurrence(kind, hour: cal.component(.hour, from: date), minute: cal.component(.minute, from: date), after: Date())
        return (r, next ?? date)
    }

    // MARK: Snooze

    static func isSnooze(_ t: String) -> Bool {
        matches(#"\b(snooze|remind me again|ask me again|try again in)\b"#, t)
    }

    static func snoozeMinutes(_ t: String) -> Int {
        let pattern = #"(\d+|an?|one|two|three|four|five|ten|fifteen|twenty|thirty|forty[- ]?five|sixty)\s*(minutes?|mins?|hours?|hrs?)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let a = Range(m.range(at: 1), in: t), let u = Range(m.range(at: 2), in: t) else { return 10 }
        let n = number(String(t[a]))
        return max(1, Int(t[u].lowercased().hasPrefix("h") ? n * 60 : n))
    }

    static func repeatPhrase(_ rule: String, at date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let t = f.string(from: date)
        switch RepeatKind(rule) {
        case .daily: return "every day at \(t)"
        case .weekdays: return "every weekday at \(t)"
        case .weekly(let d): return "every \(weekdayNames[d - 1].capitalized) at \(t)"
        case .monthly(let day): return "every month on day \(day) at \(t)"
        case nil: return ""
        }
    }

    static let timerTask = "timer"

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isReminderRequest(_ t: String) -> Bool {
        matches(#"\b(remind me|remind us|set (?:a |an |another )?(?:reminder|timer|alarm)|reminder (?:to|for|about)|wake me)\b"#, t)
    }

    static func isListRequest(_ t: String) -> Bool {
        matches(#"\b(what are my reminders|what reminders|list (?:my |all )?reminders|show (?:me )?(?:my )?reminders|any reminders|do i have (?:any )?reminders|what's on my reminders)\b"#, t)
    }

    static func isCancelAll(_ t: String) -> Bool {
        matches(#"\b(cancel|clear|delete|remove)\b.*\b(all )?(my )?reminders\b"#, t)
    }

    static func isNevermind(_ t: String) -> Bool {
        matches(#"\b(never ?mind|cancel that|forget it|forget that|skip it)\b"#, t)
    }

    // MARK: Parsing

    static func parse(_ input: String, now: Date = Date()) -> Parsed {
        var text = input
        let isTimer = matches(#"\b(timer|alarm)\b"#, text)
        var date: Date?
        let repeating = extractRepeat(&text)

        // 1. Relative: "in 20 minutes", "in an hour", "in half an hour", "timer for 10 minutes"
        let words = #"an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty[- ]?five|forty|sixty|ninety|\d+(?:\.\d+)?"#
        let lead = isTimer ? "in|after|for" : "in|after"
        let rel = #"\b(?:"# + lead + #")\s+(half an?|"# + words + #")\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?)\b"#
        if let re = try? NSRegularExpression(pattern: rel, options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let qr = Range(m.range(at: 1), in: text), let ur = Range(m.range(at: 2), in: text),
           let whole = Range(m.range, in: text) {
            let amount = number(String(text[qr]))
            let unit = text[ur].lowercased()
            let seconds: Double = unit.hasPrefix("sec") ? 1 : unit.hasPrefix("min") ? 60 : unit.hasPrefix("h") ? 3600 : 86400
            date = now.addingTimeInterval(amount * seconds)
            text.removeSubrange(whole)
        }

        // 2. Absolute / calendar phrases: "tomorrow at 9", "at 5 pm", "next Tuesday at noon"
        if date == nil, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           var d = m.date, let whole = Range(m.range, in: text) {
            // A time that already passed today means tomorrow ("remind me at 7 am" said at 9 pm).
            if d <= now && now.timeIntervalSince(d) < 86400 { d = d.addingTimeInterval(86400) }
            if d > now { date = d }
            text.removeSubrange(whole)
        }

        // 2b. Repeating: keep only the time of day and compute the next occurrence.
        var repeatRule: String?
        if let rep = repeating {
            repeatRule = rep.rule
            let cal = Calendar.current
            var hour: Int?
            var minute = 0
            if let d = date {
                hour = cal.component(.hour, from: d)
                minute = cal.component(.minute, from: d)
            } else if let h = rep.defaultHour {
                hour = h
            }
            if let h = hour {
                var rule = rep.rule
                if rule == "weekly:0" { rule = "weekly:\(cal.component(.weekday, from: date ?? now))" }
                if rule == "monthly:0" { rule = "monthly:\(cal.component(.day, from: date ?? now))" }
                repeatRule = rule
                if let kind = RepeatKind(rule) { date = nextOccurrence(kind, hour: h, minute: minute, after: now) }
            } else {
                date = nil
            }
        }

        // 3. Task text
        let prefix = #"^\s*(?:hey |ok |okay )?(?:can you |could you |would you |please |will you )*(?:remind (?:me|us)|set (?:a |an |another )?(?:reminder|timer|alarm)|wake me up|wake me)\s*(?:to |about |that |for |of |me to )?"#
        text = text.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\b(?:in|at|on|by|for|after|tomorrow|today|tonight|this evening|this morning|this afternoon)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        // "to call mom" left over when the time came first ("at 5 remind me to call mom")
        text = text.replacingOccurrences(of: #"^(?:to|that)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])

        var task: String? = text.count >= 2 ? text : nil
        if task == nil && isTimer { task = timerTask }
        return Parsed(task: task, date: date, repeatRule: repeatRule)
    }

    private static func number(_ s: String) -> Double {
        let w = s.lowercased()
        if w.hasPrefix("half") { return 0.5 }
        if let d = Double(w) { return d }
        let map: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                     "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
                                     "thirty": 30, "forty": 40, "fortyfive": 45, "forty five": 45, "forty-five": 45, "sixty": 60, "ninety": 90]
        return map[w] ?? 1
    }

    // MARK: Wording

    /// "call my mom" → "call your mom", so the reminder reads naturally back to you.
    static func secondPerson(_ s: String) -> String {
        var t = " " + s + " "
        let swaps: [(String, String)] = [(" my ", " your "), (" me ", " you "), (" myself ", " yourself "), (" mine ", " yours "),
                                         (" i'm ", " you're "), (" i am ", " you are "), (" i've ", " you've "), (" i ", " you "),
                                         (" i'll ", " you'll "), (" i'd ", " you'd ")]
        for (a, b) in swaps { t = t.replacingOccurrences(of: a, with: b, options: .caseInsensitive) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// What BOT says out loud when the reminder goes off.
    static func spokenLine(for task: String) -> String {
        task == timerTask ? "Your timer is up." : "Reminder: \(secondPerson(task))."
    }

    static func bannerText(for task: String) -> String {
        task == timerTask ? "Your timer is up" : secondPerson(task).capitalizedFirst
    }

    /// "in 10 minutes", "at 5:00 PM", "tomorrow at 9:00 AM", "on Friday at 2:00 PM"
    static func whenPhrase(_ date: Date, now: Date = Date()) -> String {
        let secs = date.timeIntervalSince(now)
        if secs < 90 { return "in a minute" }
        if secs < 3600 { return "in \(Int((secs / 60).rounded())) minutes" }
        let cal = Calendar.current
        let time = DateFormatter(); time.dateFormat = "h:mm a"
        let t = time.string(from: date)
        if cal.isDateInToday(date) { return "at \(t)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(t)" }
        let day = DateFormatter()
        day.dateFormat = secs < 6 * 86400 ? "EEEE" : "MMMM d"
        return "on \(day.string(from: date)) at \(t)"
    }
}
