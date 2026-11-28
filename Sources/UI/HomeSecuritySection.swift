import SwiftUI

/// Settings: connect BOT to the Home Security dashboard on the mini PC.
struct HomeSecuritySection: View {
    @EnvironmentObject var engine: ConversationEngine
    @State private var addressField = ""
    @State private var keyField = ""
    @State private var report = ""
    @State private var testing = false

    var body: some View {
        HomeSecurityForm(home: engine.home, addressField: $addressField, keyField: $keyField, report: $report, testing: $testing)
    }
}

private struct HomeSecurityForm: View {
    @ObservedObject var home: HomeSecurity
    @Binding var addressField: String
    @Binding var keyField: String
    @Binding var report: String
    @Binding var testing: Bool

    var body: some View {
        Section {
            if home.isConfigured {
                LabeledContent("Dashboard", value: home.address.replacingOccurrences(of: "https://", with: ""))
                LabeledContent("Key", value: "Saved")
                Button {
                    Task { testing = true; report = await home.test(); testing = false }
                } label: {
                    Label(testing ? "Testing..." : "Test connection", systemImage: "house.and.flag.fill")
                }
                .disabled(testing)
                if !report.isEmpty { Text(report).font(.footnote).foregroundStyle(.secondary) }
                Button("Disconnect", role: .destructive) { home.forget(); report = "" }
            } else {
                TextField("Dashboard address", text: $addressField)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Key", text: $keyField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") {
                    home.save(address: addressField, key: keyField)
                    keyField = ""
                    Task { testing = true; report = await home.test(); testing = false }
                }
                .disabled(addressField.trimmingCharacters(in: .whitespaces).isEmpty || keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                if !report.isEmpty { Text(report).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { Text("Home Security") } footer: {
            Text("Control both homes by voice: \u{201C}arm Hawkins\u{201D}, \u{201C}lock the front door\u{201D}, \u{201C}turn off the office light\u{201D}, \u{201C}close the van garage\u{201D}, \u{201C}set Viewmount to 21 degrees\u{201D}, \u{201C}how much propane is left?\u{201D}, \u{201C}is everything okay at home?\u{201D} or \u{201C}show me the cameras\u{201D}. BOT asks you to say yes before it disarms, unlocks, opens a garage, turns cameras off or reboots Starlink. The address and key are in the dashboard under Settings, BOT voice control. Tailscale has to be switched on.")
        }
    }
}
