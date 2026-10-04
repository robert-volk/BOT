import Foundation

// MARK: - Accounts

enum EmailProvider: String, CaseIterable, Identifiable {
    case icloud, yahoo, gmail, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .icloud: return "iCloud"
        case .yahoo: return "Yahoo"
        case .gmail: return "Gmail"
        case .other: return "Work / other (IMAP)"
        }
    }

    var imapHost: String {
        switch self {
        case .icloud: return "imap.mail.me.com"
        case .yahoo: return "imap.mail.yahoo.com"
        case .gmail: return "imap.gmail.com"
        case .other: return ""
        }
    }

    var smtpHost: String {
        switch self {
        case .icloud: return "smtp.mail.me.com"
        case .yahoo: return "smtp.mail.yahoo.com"
        case .gmail: return "smtp.gmail.com"
        case .other: return ""
        }
    }

    var smtpPort: Int {
        switch self {
        case .icloud: return 587
        case .yahoo, .gmail: return 465
        case .other: return 587
        }
    }

    var passwordHelp: String {
        switch self {
        case .icloud: return "Use an app-specific password: sign in at appleid.apple.com, Sign-In and Security, App-Specific Passwords."
        case .yahoo: return "Use an app password: Yahoo Account Security, Generate app password."
        case .gmail: return "Use an app password (2-Step Verification must be on): myaccount.google.com, Security, App passwords."
        case .other: return "Use your mail password or an app password, and your provider's IMAP and SMTP server names. Many work and school accounts block this."
        }
    }
}

struct EmailAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var address: String
    var username: String
    var imapHost: String
    var smtpHost: String
    var smtpPort: Int
}

/// Your mail accounts. Settings are stored in Application Support; passwords only in the Keychain.
@MainActor
final class EmailStore: ObservableObject {
    @Published private(set) var accounts: [EmailAccount] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BOT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("email-accounts.json")
        if let d = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([EmailAccount].self, from: d) {
            accounts = decoded
        }
    }

    func password(for account: EmailAccount) -> String {
        Keychain.get("mail-\(account.id.uuidString)") ?? ""
    }

    func add(_ account: EmailAccount, password: String) {
        Keychain.set(password, for: "mail-\(account.id.uuidString)")
        accounts.append(account)
        save()
    }

    func remove(_ account: EmailAccount) {
        Keychain.set("", for: "mail-\(account.id.uuidString)")
        accounts.removeAll { $0.id == account.id }
        save()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(accounts) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Messages

struct MailMessage {
    var accountID: UUID
    var accountLabel: String
    var uid: Int
    var fromName: String
    var fromAddress: String
    var replyTo: String
    var subject: String
    var snippet: String
    var messageID: String
    var references: String
}

struct EmailDraft {
    var accountID: UUID
    var accountLabel: String
    var toName: String
    var to: String
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: String?
}

struct UnreadReport {
    var label: String
    var count: Int
    var messages: [MailMessage]
}

/// Talks to the mail servers. Everything stays between this phone and your mail provider.
@MainActor
final class EmailService {
    let store: EmailStore

    init(store: EmailStore) { self.store = store }

    // MARK: Sessions

    private func withInbox<T>(_ account: EmailAccount, _ work: (IMAPClient) async throws -> T) async throws -> T {
        let password = store.password(for: account)
        var users = [account.username]
        if let local = account.address.split(separator: "@").first.map(String.init), local != account.username { users.append(local) }

        var lastError: Error = MailError.auth
        for user in users {
            let client = IMAPClient(host: account.imapHost)
            do {
                try await client.login(user: user, password: password)
                try await client.examineInbox()
                let result = try await work(client)
                await client.logout()
                return result
            } catch MailError.auth {
                lastError = MailError.auth   // try the shorter username (iCloud accepts either)
            } catch {
                await client.logout()
                throw error
            }
        }
        throw lastError
    }

    /// Checks that the address and password work, without storing anything.
    func verify(_ account: EmailAccount, password: String) async throws {
        var users = [account.username]
        if let local = account.address.split(separator: "@").first.map(String.init), local != account.username { users.append(local) }
        var lastError: Error = MailError.auth
        for user in users {
            let client = IMAPClient(host: account.imapHost)
            do {
                try await client.login(user: user, password: password)
                await client.logout()
                return
            } catch MailError.auth {
                lastError = MailError.auth
            } catch {
                throw error
            }
        }
        throw lastError
    }

    // MARK: Reading

    private func message(from raw: RawMessage, account: EmailAccount) -> MailMessage {
        let headers = MailParsing.parseHeaders(raw.header)
        let from = MailParsing.parseAddress(headers["from"] ?? "")
        let replyTo = MailParsing.parseAddress(headers["reply-to"] ?? headers["from"] ?? "").address
        let subject = MailParsing.decodeWords(headers["subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return MailMessage(accountID: account.id, accountLabel: account.label, uid: raw.uid,
                           fromName: from.name, fromAddress: from.address, replyTo: replyTo,
                           subject: subject.isEmpty ? "no subject" : subject,
                           snippet: raw.body.isEmpty ? "" : MailParsing.readableText(headers: headers, body: raw.body),
                           messageID: headers["message-id"] ?? "", references: headers["references"] ?? "")
    }

    /// Unread counts plus the newest unread messages per account.
    func unread(perAccount limit: Int, includeBody: Bool) async -> (reports: [UnreadReport], errors: [String]) {
        var reports: [UnreadReport] = []
        var errors: [String] = []
        for account in store.accounts {
            do {
                let report: UnreadReport = try await withInbox(account) { client in
                    let uids = try await client.search("UNSEEN")
                    let newest = Array(uids.suffix(limit).reversed())
                    let raw = try await client.fetch(uids: newest, includeBody: includeBody)
                    let ordered = newest.compactMap { uid in raw.first { $0.uid == uid } }
                    return UnreadReport(label: account.label, count: uids.count,
                                        messages: ordered.map { self.message(from: $0, account: account) })
                }
                reports.append(report)
            } catch {
                errors.append("\(account.label): \(error.localizedDescription)")
            }
        }
        return (reports, errors)
    }

    /// Newest messages from a sender (read or unread) across accounts.
    func search(from sender: String, limit: Int) async -> (messages: [MailMessage], errors: [String]) {
        var found: [MailMessage] = []
        var errors: [String] = []
        let criteria = "FROM " + IMAPClient.quote(sender)
        for account in store.accounts {
            do {
                let messages: [MailMessage] = try await withInbox(account) { client in
                    let uids = try await client.search(criteria)
                    let newest = Array(uids.suffix(limit).reversed())
                    let raw = try await client.fetch(uids: newest, includeBody: true)
                    let ordered = newest.compactMap { uid in raw.first { $0.uid == uid } }
                    return ordered.map { self.message(from: $0, account: account) }
                }
                found += messages
            } catch {
                errors.append("\(account.label): \(error.localizedDescription)")
            }
        }
        return (Array(found.prefix(limit)), errors)
    }

    // MARK: Sending

    func send(_ draft: EmailDraft) async throws {
        guard let account = store.accounts.first(where: { $0.id == draft.accountID }) else {
            throw MailError.connection("That account isn't set up anymore.")
        }
        let password = store.password(for: account)
        let message = MailComposer.build(fromAddress: account.address, to: draft.to, subject: draft.subject,
                                         body: draft.body, inReplyTo: draft.inReplyTo, references: draft.references)
        var users = [account.username]
        if let local = account.address.split(separator: "@").first.map(String.init), local != account.username { users.append(local) }
        var lastError: Error = MailError.auth
        for user in users {
            let client = SMTPClient(host: account.smtpHost, port: account.smtpPort)
            do {
                try await client.deliver(from: account.address, user: user, password: password, to: draft.to, message: message)
                return
            } catch MailError.auth {
                lastError = MailError.auth
            }
        }
        throw lastError
    }
}
