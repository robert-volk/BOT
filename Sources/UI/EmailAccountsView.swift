import SwiftUI

/// Add, check and remove the mail accounts BOT can read and send from.
struct EmailAccountsView: View {
    @EnvironmentObject var emailStore: EmailStore
    @State private var adding = false

    var body: some View {
        List {
            Section {
                if emailStore.accounts.isEmpty {
                    Text("No accounts yet").foregroundStyle(.secondary)
                }
                ForEach(emailStore.accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                        Text(account.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { emailStore.accounts[$0] }
                    for account in doomed { emailStore.remove(account) }
                }
            } footer: {
                Text("Passwords are kept in the iPhone Keychain. Email goes only between this phone and your mail provider. It is never sent to Claude or any search service; summaries use Apple's on-device AI when your iPhone has it, otherwise BOT reads the subject and first line. BOT never marks mail as read, and never sends anything until you say \"send it\".")
            }
            Section {
                Button { adding = true } label: { Label("Add an account", systemImage: "plus.circle.fill") }
            }
            Section("What you can say") {
                Text("\u{201C}Do I have any new email?\u{201D}")
                Text("\u{201C}Read my unread emails.\u{201D}")
                Text("\u{201C}Read emails from Dana.\u{201D}")
                Text("\u{201C}Reply that Thursday works.\u{201D}")
                Text("\u{201C}Email Sam that I'll be late.\u{201D}")
            }
            .font(.footnote)
        }
        .navigationTitle("Email accounts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) {
            AddEmailAccountView().environmentObject(emailStore)
        }
    }
}

struct AddEmailAccountView: View {
    @EnvironmentObject var emailStore: EmailStore
    @Environment(\.dismiss) private var dismiss

    @State private var provider: EmailProvider = .icloud
    @State private var label = ""
    @State private var address = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(EmailProvider.allCases) { Text($0.title).tag($0) }
                }
                TextField("Name (for example Personal)", text: $label)
                TextField("Email address", text: $address)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("App-specific password", text: $password)
                if provider == .other {
                    TextField("IMAP server (imap.example.com)", text: $imapHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("SMTP server (smtp.example.com)", text: $smtpHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("SMTP port (587 or 465)", text: $smtpPort).keyboardType(.numberPad)
                }
                Text(provider.passwordHelp).font(.footnote).foregroundStyle(.secondary)
                if let status {
                    Text(status).font(.footnote)
                        .foregroundStyle(status.hasPrefix("Connected") ? Color.green : Color.red)
                }
                Button(busy ? "Checking..." : "Check and save") {
                    Task { await save() }
                }
                .disabled(busy || address.isEmpty || password.isEmpty || (provider == .other && (imapHost.isEmpty || smtpHost.isEmpty)))
            }
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    @MainActor
    private func save() async {
        busy = true
        defer { busy = false }
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = EmailAccount(
            label: label.trimmingCharacters(in: .whitespaces).isEmpty ? provider.title : label,
            address: trimmedAddress,
            username: trimmedAddress,
            imapHost: provider == .other ? imapHost.trimmingCharacters(in: .whitespaces) : provider.imapHost,
            smtpHost: provider == .other ? smtpHost.trimmingCharacters(in: .whitespaces) : provider.smtpHost,
            smtpPort: provider == .other ? (Int(smtpPort) ?? 587) : provider.smtpPort)
        status = "Connecting..."
        do {
            try await EmailService(store: emailStore).verify(account, password: password)
            emailStore.add(account, password: password)
            status = "Connected."
            dismiss()
        } catch {
            status = error.localizedDescription
        }
    }
}
