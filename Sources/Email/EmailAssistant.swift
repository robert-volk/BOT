import Foundation

/// Voice control of your email. Privacy rule: email text is only ever handled by the mail servers, this phone,
/// and Apple's on-device AI (when your iPhone has it). It is never sent to Claude or any search service.
@MainActor
final class EmailAssistant {
    enum Intent {
        case check
        case readUnread
        case readFrom(String)
        case reply(String)
        case compose(to: String, body: String, viaMail: Bool)
        case workUnsupported
    }

    let service: EmailService
    private let phone: PhoneActions
    private var lastMessages: [MailMessage] = []
    private var lastRead: MailMessage?
    private var lastReadAt = Date.distantPast
    private var pendingDraft: EmailDraft?
    private var awaitingBody: EmailDraft?

    init(service: EmailService, phone: PhoneActions) {
        self.service = service
        self.phone = phone
    }

    var hasAccounts: Bool { !service.store.accounts.isEmpty }

    // MARK: Parsing

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static let workMessage = "I can't read your work mailbox, but Siri can: try Hey Siri, read my new emails. I can still open the Mail app with a new message for you. Say email, a name, in Mail, and what to say."

    /// "email Sam in Mail ...", "from my work account ..." send a draft to the Mail app instead of BOT's own accounts.
    static func parse(_ raw: String) -> Intent? {
        var t = raw
        var viaMail = false
        let trailing = #"\s*,?\s*\b(?:in|with|using|via|through|from)\s+(?:the |my )?(?:mail app|apple mail|mail|work e-?mail|work account|work mail|work)\b(?:\s+(?:app|account))?"#
        let leading = #"^(?:please )?(?:open|use|launch)\s+(?:the )?(?:mail app|apple mail|mail)(?:\s+and)?\s+"#
        if t.range(of: trailing, options: [.regularExpression, .caseInsensitive]) != nil {
            viaMail = true
            t = t.replacingOccurrences(of: trailing, with: "", options: [.regularExpression, .caseInsensitive])
        }
        if t.range(of: leading, options: [.regularExpression, .caseInsensitive]) != nil {
            viaMail = true
            t = t.replacingOccurrences(of: leading, with: "", options: [.regularExpression, .caseInsensitive])
        }
        guard let intent = parseCore(t) else { return viaMail ? .workUnsupported : nil }
        if case .compose(let to, let body, _) = intent { return .compose(to: to, body: body, viaMail: viaMail) }
        return viaMail ? .workUnsupported : intent
    }

    private static func parseCore(_ raw: String) -> Intent? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))

        if let g = firstMatch(#"^(?:please )?(?:send|write|compose|draft|shoot)\s+(?:an? |a quick )?e-?mail\s+to\s+(.+?)(?:\s+(?:saying|that says|and say|telling (?:him|her|them)(?: that)?|that|about)\s+(.+))?$"#, in: t)
            ?? firstMatch(#"^e-?mail\s+(.+?)\s+(?:saying|that says|and say|telling (?:him|her|them)(?: that)?|that|about)\s+(.+)$"#, in: t) {
            return .compose(to: g[0], body: g.count > 1 ? g[1] : "", viaMail: false)
        }
        if let g = firstMatch(#"^(?:please )?e-?mail\s+([A-Za-z][A-Za-z .'@-]{1,40})$"#, in: t) {
            return .compose(to: g[0], body: "", viaMail: false)
        }
        if let g = firstMatch(#"^(?:please )?(?:reply|respond|write back)\b(?:\s+to\s+(?:that|this|it|him|her|them|the e-?mail|that e-?mail|the last one))?[,:]?\s*(?:saying|and say|that says|with|telling (?:him|her|them)(?: that)?|that)?\s*(.*)$"#, in: t) {
            return .reply(g[0])
        }
        if let g = firstMatch(#"\b(?:read|show|any|do i have|check|what'?s|get)\b.{0,30}\be-?mails?\s+from\s+(.+)$"#, in: t) {
            return .readFrom(g[0])
        }
        if firstMatch(#"^(?:please )?(?:read|go through|go over|tell me)\s+(?:me )?(?:my |the )?(?:unread |new )?(?:e-?mails?|messages|inbox)\b"#, in: t) != nil
            || firstMatch(#"^read (?:them|those|it)$"#, in: t) != nil {
            return .readUnread
        }
        if firstMatch(#"\b(?:do i have|any|check|how many|what'?s in|anything in|got any)\b.{0,25}\b(?:e-?mails?|inbox|mail)\b"#, in: t) != nil
            || firstMatch(#"^(?:check|open) (?:my )?(?:e-?mail|inbox|mail)$"#, in: t) != nil {
            return .check
        }
        return nil
    }

    private static func isConfirm(_ t: String) -> Bool {
        t.range(of: #"^(?:yes[,. ]*)?(?:please )?(?:send it|send that|send|go ahead|confirm|looks good|sounds good)\b|^yes\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isCancel(_ t: String) -> Bool {
        t.range(of: #"^(?:no[,. ]*)?(?:cancel|don'?t send|do not send|never ?mind|discard|stop|scrap it|no)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Should the engine route this utterance here?
    func wantsToHandle(_ text: String) -> Bool {
        if pendingDraft != nil || awaitingBody != nil { return true }
        guard let intent = Self.parse(text) else { return false }
        if case .reply = intent { return lastRead != nil && Date().timeIntervalSince(lastReadAt) < 600 }
        return true
    }

    // MARK: Responding

    func respond(to text: String, userName: String?, onDevice: Brain?) async -> String {
        // Follow-ups to a draft
        if let draft = pendingDraft {
            if Self.isConfirm(text) {
                pendingDraft = nil
                do {
                    try await service.send(draft)
                    return "Sent to \(draft.toName)."
                } catch {
                    return "I couldn't send it. \(error.localizedDescription)"
                }
            }
            pendingDraft = nil
            if Self.isCancel(text) { return "Okay, I won't send it." }
        }
        if var draft = awaitingBody {
            awaitingBody = nil
            if Self.isCancel(text) { return "Okay, never mind." }
            draft.body = await polish(text, to: draft.toName, userName: userName, brain: onDevice)
            if draft.subject.isEmpty { draft.subject = Self.subject(from: text) }
            if draft.viaMail { return openInMail(draft) }
            pendingDraft = draft
            return readBack(draft)
        }

        guard let intent = Self.parse(text) else { return "Sorry, I didn't catch that." }
        if case .workUnsupported = intent { return Self.workMessage }
        // Work mail, or no accounts added: hand the draft to the Mail app.
        if case .compose(let to, let body, let viaMail) = intent, viaMail || !hasAccounts {
            return await composeInMail(to: to, body: body, userName: userName, brain: onDevice)
        }
        guard hasAccounts else {
            return "You haven't added an email account yet. Open Customize, then Email accounts, to add one."
        }

        switch intent {
        case .check:
            return await check()
        case .readUnread:
            return await readUnread(brain: onDevice)
        case .readFrom(let sender):
            return await readFrom(sender, brain: onDevice)
        case .reply(let instruction):
            return await reply(instruction, userName: userName, brain: onDevice)
        case .workUnsupported:
            return Self.workMessage
        case .compose(let to, let body, _):
            return await compose(to: to, body: body, userName: userName, brain: onDevice)
        }
    }

    // MARK: Reading

    private func check() async -> String {
        let result = await service.unread(perAccount: 3, includeBody: false)
        let total = result.reports.reduce(0) { $0 + $1.count }
        var parts: [String] = []
        if total == 0 {
            parts.append(result.reports.isEmpty ? "" : "You have no unread email.")
        } else {
            let perAccount = result.reports.filter { $0.count > 0 }.map { "\($0.count) in \($0.label)" }
            parts.append("You have \(total) unread email\(total == 1 ? "" : "s"): " + ListStore.joined(perAccount) + ".")
            let newest = result.reports.flatMap { $0.messages }.prefix(3)
            lastMessages = Array(newest)
            if !newest.isEmpty {
                parts.append("The newest are from " + ListStore.joined(newest.map { "\($0.fromName) about \($0.subject)" }) + ". Say read them to hear more.")
            }
        }
        if !result.errors.isEmpty { parts.append("I couldn't check " + result.errors.joined(separator: "; ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func readUnread(brain: Brain?) async -> String {
        let result = await service.unread(perAccount: 3, includeBody: true)
        let messages = Array(result.reports.flatMap { $0.messages }.prefix(3))
        lastMessages = messages
        guard !messages.isEmpty else {
            return result.errors.isEmpty ? "You have no unread email." : "I couldn't check " + result.errors.joined(separator: "; ")
        }
        return await narrate(messages, brain: brain) + (result.errors.isEmpty ? "" : " I couldn't check " + result.errors.joined(separator: "; "))
    }

    private func readFrom(_ sender: String, brain: Brain?) async -> String {
        let name = sender.trimmingCharacters(in: .whitespaces)
        let result = await service.search(from: name, limit: 2)
        lastMessages = result.messages
        guard !result.messages.isEmpty else {
            return result.errors.isEmpty ? "I didn't find any email from \(name)." : "I couldn't search: " + result.errors.joined(separator: "; ")
        }
        return await narrate(result.messages, brain: brain)
    }

    private func narrate(_ messages: [MailMessage], brain: Brain?) async -> String {
        var spoken: [String] = []
        for (i, m) in messages.enumerated() {
            let summary = await summarize(m, brain: brain)
            spoken.append("Email \(i + 1), from \(m.fromName), subject \(m.subject). \(summary)")
        }
        lastRead = messages.last
        lastReadAt = Date()
        return spoken.joined(separator: " ") + " Say reply to answer" + (messages.count > 1 ? " the last one." : ".")
    }

    private func summarize(_ m: MailMessage, brain: Brain?) async -> String {
        let text = m.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let brain {
            let prompt = "From: \(m.fromName)\nSubject: \(m.subject)\n\n\(String(text.prefix(1500)))"
            let system = "You summarize an email for someone listening. One short plain sentence, no markdown. Skip greetings and signatures."
            if let out = try? await brain.complete(system: system, prompt: prompt, maxTokens: 70) {
                let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && clean.uppercased() != "NONE" { return clean }
            }
        }
        // No on-device AI: read the opening line.
        let first = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        return String(first.prefix(160)) + "."
    }

    // MARK: Writing

    private func reply(_ instruction: String, userName: String?, brain: Brain?) async -> String {
        guard let last = lastRead else { return "I don't have an email to reply to. Ask me to read your email first." }
        guard let account = service.store.accounts.first(where: { $0.id == last.accountID }) ?? service.store.accounts.first else {
            return "That account isn't set up anymore."
        }
        var subject = last.subject
        if subject.range(of: #"^(?:re|fwd?):"#, options: [.regularExpression, .caseInsensitive]) == nil { subject = "Re: " + subject }
        var draft = EmailDraft(accountID: account.id, accountLabel: account.label, toName: last.fromName, to: last.replyTo,
                               subject: subject, body: "", inReplyTo: last.messageID, references: last.references)
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            awaitingBody = draft
            return "What should I say to \(last.fromName)?"
        }
        draft.body = await polish(trimmed, to: last.fromName, userName: userName, brain: brain)
        pendingDraft = draft
        return readBack(draft)
    }

    private func compose(to: String, body: String, userName: String?, brain: Brain?) async -> String {
        guard let account = service.store.accounts.first else { return "Add an email account first." }
        guard let (name, address) = await resolveRecipient(to) else {
            return "I couldn't find an email address for \(to). Try saying the address, or add it to your contacts."
        }
        var draft = EmailDraft(accountID: account.id, accountLabel: account.label, toName: name, to: address,
                               subject: "", body: "", inReplyTo: nil, references: nil)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            awaitingBody = draft
            return "What would you like to say to \(name)?"
        }
        draft.subject = Self.subject(from: trimmed)
        draft.body = await polish(trimmed, to: name, userName: userName, brain: brain)
        pendingDraft = draft
        return readBack(draft)
    }

    // MARK: Mail app hand-off

    private var mailURL: URL?

    /// A mailto: link for the engine to open once BOT has finished speaking.
    func takeMailURL() -> URL? {
        defer { mailURL = nil }
        return mailURL
    }

    private func composeInMail(to: String, body: String, userName: String?, brain: Brain?) async -> String {
        guard let (name, address) = await resolveRecipient(to, preferWork: true) else {
            return "I couldn't find an email address for \(to). Try saying the address, or add it to your contacts."
        }
        var draft = EmailDraft(accountID: UUID(), accountLabel: "Mail", toName: name, to: address,
                               subject: "", body: "", inReplyTo: nil, references: nil)
        draft.viaMail = true
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            awaitingBody = draft
            return "What would you like to say to \(name)?"
        }
        draft.subject = Self.subject(from: trimmed)
        draft.body = await polish(trimmed, to: name, userName: userName, brain: brain)
        return openInMail(draft)
    }

    private func openInMail(_ d: EmailDraft) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        let subject = d.subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let body = d.body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        mailURL = URL(string: "mailto:\(d.to)?subject=\(subject)&body=\(body)")
        return "Opening Mail with your message to \(d.toName). Choose your work account as the sender, check it, and tap Send."
    }

    private func readBack(_ d: EmailDraft) -> String {
        "Here's the email to \(d.toName), from your \(d.accountLabel) account. Subject: \(d.subject). "
            + "It says: " + d.body.replacingOccurrences(of: "\n", with: " ") + " Say send it to send, or cancel."
    }

    /// Turns "that I'm running late" into a short, polite email body. The on-device AI writes it when available.
    private func polish(_ instruction: String, to name: String, userName: String?, brain: Brain?) async -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let signOff = userName.map { "\n\nThanks,\n\($0)" } ?? ""
        let plain = instruction.trimmingCharacters(in: .whitespacesAndNewlines).capitalizedFirst
        let literal = "Hi \(first),\n\n" + plain + (plain.last.map { ".!?".contains($0) } == true ? "" : ".") + signOff
        guard let brain else { return literal }
        let system = "You write short, polite, natural emails from the user's instruction, in first person as the user. Output only the email body: a greeting line and one to three short sentences. No sign-off, no signature, no subject line."
        let prompt = "Recipient: \(name)\nInstruction: \(instruction)"
        guard let out = try? await brain.complete(system: system, prompt: prompt, maxTokens: 180) else { return literal }
        let body = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty || body.uppercased() == "NONE" { return literal }
        return body + signOff
    }

    private static func subject(from text: String) -> String {
        let words = text.split(separator: " ").prefix(6).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        return trimmed.isEmpty ? "Hello" : trimmed.capitalizedFirst
    }

    /// A spoken address ("sam at gmail dot com") or a contact's email.
    private func resolveRecipient(_ spoken: String, preferWork: Bool = false) async -> (String, String)? {
        let normalized = spoken.lowercased()
            .replacingOccurrences(of: " at ", with: "@")
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " ", with: "")
        if normalized.range(of: #"^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil {
            return (normalized, normalized)
        }
        guard await phone.requestAccess() else { return nil }
        guard let match = phone.findEmail(spoken, preferWork: preferWork) else { return nil }
        return match
    }
}
