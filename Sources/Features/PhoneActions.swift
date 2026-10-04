import Foundation
import Contacts
import UIKit

/// "Call Mom", "text Sam I'm running late", "directions to the airport", "find a coffee shop near me".
enum PhoneIntent {
    case call(name: String)
    case text(name: String, body: String)
    case directions(place: String)
    case nearby(query: String)

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func parse(_ raw: String) -> PhoneIntent? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))

        if let g = firstMatch(#"^(?:please )?(?:send (?:a )?(?:text|message)(?: to)?|text|message)\s+(.+?)\s+(?:saying|that says|and say|telling (?:him|her|them)|to say|that)\s+(.+)$"#, in: t) {
            return .text(name: g[0], body: g[1])
        }
        if let g = firstMatch(#"^(?:please )?(?:send (?:a )?(?:text|message) to|text|message)\s+([A-Za-z][A-Za-z .'-]{1,30})$"#, in: t) {
            return .text(name: g[0], body: "")
        }
        if let g = firstMatch(#"^(?:please )?(?:call|phone|dial|ring)\s+(.+)$"#, in: t),
           !g[0].lowercased().hasPrefix("me"), !g[0].lowercased().hasPrefix("it ") {
            return .call(name: g[0])
        }
        if let g = firstMatch(#"^(?:please )?(?:give me |get me |show me )?(?:directions|navigate|navigation)(?: to| there)?\s*(.*)$"#, in: t)
            ?? firstMatch(#"^(?:please )?(?:take me|drive me|how do i get|how can i get|route me)\s+(?:to|there|home)\s*(.*)$"#, in: t) {
            var place = g[0].trimmingCharacters(in: .whitespaces)
            if place.isEmpty { place = t.lowercased().hasSuffix("home") ? "home" : "there" }
            return .directions(place: place)
        }
        if let g = firstMatch(#"^(?:find|show me|search for|where'?s|where is|look for)\s+(?:me )?(?:a |an |the |some )?(.+?)\s+(?:near me|nearby|around here|close by|near here)$"#, in: t) {
            return .nearby(query: g[0])
        }
        if let g = firstMatch(#"^(?:where'?s|where is|find)\s+(?:the )?(?:nearest|closest)\s+(.+)$"#, in: t) {
            return .nearby(query: g[0])
        }
        if let g = firstMatch(#"^(?:is there|are there)\s+(?:a |an |any )?(.+?)\s+(?:near me|nearby|around here)$"#, in: t) {
            return .nearby(query: g[0])
        }
        return nil
    }
}

struct ContactMatch {
    var name: String
    var number: String   // digits and leading +
}

/// Looks people up in Contacts (read-only, after you allow it). BOT never places a call or sends a text by itself:
/// iOS asks you to confirm the call, and the text opens pre-filled for you to tap Send.
@MainActor
final class PhoneActions {
    private let store = CNContactStore()

    func requestAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return true
        case .notDetermined: return (try? await store.requestAccess(for: .contacts)) ?? false
        default: return false
        }
    }

    var isDenied: Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        return s == .denied || s == .restricted
    }

    func find(_ spokenName: String) -> ContactMatch? {
        let name = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:my |the )"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard !name.isEmpty else { return nil }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                       CNContactNicknameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        var contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        if contacts.isEmpty {
            // Nicknames ("Mom") are often stored in the nickname field.
            let all = CNContactFetchRequest(keysToFetch: keys)
            var found: [CNContact] = []
            try? store.enumerateContacts(with: all) { c, _ in
                if c.nickname.caseInsensitiveCompare(name) == .orderedSame { found.append(c) }
            }
            contacts = found
        }
        guard let contact = contacts.first(where: { !$0.phoneNumbers.isEmpty }) else { return nil }
        let mobile = contact.phoneNumbers.first { p in
            p.label == CNLabelPhoneNumberMobile || p.label == CNLabelPhoneNumberiPhone
        }
        let chosen = mobile ?? contact.phoneNumbers[0]
        let digits = chosen.value.stringValue.filter { $0.isNumber || $0 == "+" }
        let display = CNContactFormatter.string(from: contact, style: .fullName) ?? name
        return ContactMatch(name: display, number: digits)
    }

    /// (display name, email address) for a spoken contact name.
    func findEmail(_ spokenName: String) -> (String, String)? {
        let name = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:my |the )"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard !name.isEmpty else { return nil }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                       CNContactNicknameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
                                       CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        var contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        if contacts.isEmpty {
            let all = CNContactFetchRequest(keysToFetch: keys)
            var found: [CNContact] = []
            try? store.enumerateContacts(with: all) { c, _ in
                if c.nickname.caseInsensitiveCompare(name) == .orderedSame { found.append(c) }
            }
            contacts = found
        }
        guard let contact = contacts.first(where: { !$0.emailAddresses.isEmpty }) else { return nil }
        let display = CNContactFormatter.string(from: contact, style: .fullName) ?? name
        return (display, contact.emailAddresses[0].value as String)
    }

    // MARK: Opening other apps (must be done while BOT is on screen)

    func openCall(_ number: String) {
        if let url = URL(string: "tel://\(number)") { UIApplication.shared.open(url) }
    }

    func openText(_ number: String, body: String) {
        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = body.isEmpty ? "sms:\(number)" : "sms:\(number)&body=\(encoded)"
        if let url = URL(string: urlString) { UIApplication.shared.open(url) }
    }

    func openDirections(to place: String) {
        let encoded = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? place
        if let url = URL(string: "https://maps.apple.com/?daddr=\(encoded)&dirflg=d") { UIApplication.shared.open(url) }
    }
}
