import SwiftUI
import UserNotifications

/// Tracks what BOT spends on the Claude API and warns when the estimated balance runs low.
/// Anthropic doesn't let an app read the real balance, so BOT starts from the balance you enter, subtracts the cost
/// of each request (from the token counts Claude reports, at Haiku 4.5 prices) and warns below your limit.
/// If Claude ever reports that the credit is gone, BOT warns right away whatever the estimate says.
@MainActor
final class ClaudeUsage: ObservableObject {
    static let shared = ClaudeUsage()

    // Claude Haiku 4.5 list prices (US dollars): $1 / million input tokens, $5 / million output tokens, $10 / 1000 web searches.
    private static let inputPerToken = 1.0 / 1_000_000
    private static let outputPerToken = 5.0 / 1_000_000
    private static let perSearch = 0.01

    private let defaults = UserDefaults.standard
    private enum Key {
        static let balance = "bot.claude.balance"
        static let spent = "bot.claude.spent"
        static let warn = "bot.claude.warn"
        static let threshold = "bot.claude.threshold"
        static let alerted = "bot.claude.alerted"
        static let emptyAlert = "bot.claude.emptyAlert"
    }

    /// Estimated dollars left, or nil until you enter your balance.
    @Published private(set) var balance: Double?
    /// Estimated dollars spent through BOT since you last entered the balance.
    @Published private(set) var spentSince: Double
    @Published var warnEnabled: Bool { didSet { defaults.set(warnEnabled, forKey: Key.warn); if warnEnabled { checkLow() } } }
    @Published var threshold: Double { didSet { defaults.set(threshold, forKey: Key.threshold); alerted = false; checkLow() } }

    private var alerted: Bool {
        get { defaults.bool(forKey: Key.alerted) }
        set { defaults.set(newValue, forKey: Key.alerted) }
    }

    private init() {
        balance = defaults.object(forKey: Key.balance) as? Double
        spentSince = defaults.double(forKey: Key.spent)
        warnEnabled = defaults.object(forKey: Key.warn) as? Bool ?? true
        threshold = defaults.object(forKey: Key.threshold) as? Double ?? 2.0
    }

    /// You typed your balance from the Anthropic Console (or topped up).
    func setBalance(_ dollars: Double) {
        balance = dollars
        spentSince = 0
        defaults.set(dollars, forKey: Key.balance)
        defaults.set(0.0, forKey: Key.spent)
        alerted = false
        checkLow()
    }

    nonisolated static func record(inputTokens: Int, outputTokens: Int, searches: Int) {
        guard inputTokens > 0 || outputTokens > 0 || searches > 0 else { return }
        Task { @MainActor in shared.add(inputTokens: inputTokens, outputTokens: outputTokens, searches: searches) }
    }

    /// Called with every Claude error message. Out of credit is reported at once.
    nonisolated static func reportIfOutOfCredit(_ message: String) {
        guard message.localizedCaseInsensitiveContains("credit balance is too low") else { return }
        Task { @MainActor in shared.outOfCredit() }
    }

    private func add(inputTokens: Int, outputTokens: Int, searches: Int) {
        let cost = Double(inputTokens) * Self.inputPerToken + Double(outputTokens) * Self.outputPerToken
            + Double(searches) * Self.perSearch
        guard let current = balance else { return }
        let left = current - cost
        balance = left
        spentSince += cost
        defaults.set(left, forKey: Key.balance)
        defaults.set(spentSince, forKey: Key.spent)
        checkLow()
    }

    private func checkLow() {
        guard warnEnabled, let b = balance, b < threshold, !alerted else { return }
        alerted = true
        notify(title: "Claude balance is low",
               body: String(format: "BOT estimates about $%.2f is left. Add credit at console.anthropic.com to keep BOT answering.", max(0, b)))
    }

    private func outOfCredit() {
        let now = Date().timeIntervalSince1970
        guard now - defaults.double(forKey: Key.emptyAlert) > 6 * 3600 else { return }
        defaults.set(now, forKey: Key.emptyAlert)
        if balance != nil { balance = 0; defaults.set(0.0, forKey: Key.balance) }
        alerted = true
        notify(title: "Claude credit has run out",
               body: "BOT can't answer until you add credit at console.anthropic.com.")
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "claude-balance-\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }
}

/// Settings rows for the balance warning.
struct ClaudeBalanceSection: View {
    @ObservedObject private var usage = ClaudeUsage.shared
    @State private var balanceText = ""

    private var entered: Double? {
        Double(balanceText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
    }

    var body: some View {
        Section {
            Toggle("Warn me when my Claude balance is low", isOn: $usage.warnEnabled)
            Stepper(value: $usage.threshold, in: 0.5...50, step: 0.5) {
                Text(String(format: "Warn below $%.2f", usage.threshold))
            }
            HStack {
                Text("Balance now: $")
                TextField("from the Console", text: $balanceText)
                    .keyboardType(.decimalPad)
                Button("Save") {
                    if let entered { usage.setBalance(entered); balanceText = "" }
                }
                .disabled(entered == nil)
            }
            if let b = usage.balance {
                LabeledContent("Estimated left", value: String(format: "$%.2f", max(0, b)))
                LabeledContent("Spent through BOT since", value: String(format: "$%.2f", usage.spentSince))
            }
        } header: { Text("Claude balance") } footer: {
            Text("Anthropic doesn't let apps read your real balance, so BOT estimates it: type your balance from console.anthropic.com (Billing), and BOT subtracts what each question costs and warns you below your limit. Re-enter it now and then, and after you add credit, to keep the estimate close. If Claude says your credit is gone, BOT always warns you at once.")
        }
    }
}
