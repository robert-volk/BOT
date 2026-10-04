import Foundation

/// Exact unit and currency conversions. Units are computed on-device; currency uses frankfurter.app
/// (free, no key, European Central Bank rates).
enum Conversions {
    struct Request {
        var value: Double
        var from: String
        var to: String
    }

    static func parse(_ raw: String) -> Request? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        if let flipped = parseUnitFirst(t) { return flipped }
        let pattern = #"(?:convert|how many|how much is|how much|what'?s|what is|what are)\s+(?:is |are )?(-?[\d,]*\.?\d+)\s*(?:degrees? )?([a-zA-Z°/ ]+?)\s+(?:to|in|into|equal in|are in|is in)\s+(?:degrees? )?([a-zA-Z°/ ]+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let a = Range(m.range(at: 1), in: t), let b = Range(m.range(at: 2), in: t), let c = Range(m.range(at: 3), in: t),
              let value = Double(t[a].replacingOccurrences(of: ",", with: "")) else { return nil }
        let from = t[b].lowercased().trimmingCharacters(in: .whitespaces)
        let to = t[c].lowercased().trimmingCharacters(in: .whitespaces)
        let req = Request(value: value, from: from, to: to)
        // Only claim it if we can actually convert it; otherwise it's a normal question for the AI.
        if currencyPair(req) != nil || unitPair(req) != nil { return req }
        return nil
    }

    /// "how many miles are in 5 kilometers" (unit first).
    private static func parseUnitFirst(_ t: String) -> Request? {
        let pattern = #"^how many\s+([a-zA-Z°/ ]+?)\s+(?:are|is)\s+(?:there\s+)?in\s+(-?[\d,]*\.?\d+)\s*([a-zA-Z°/ ]+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let to = Range(m.range(at: 1), in: t), let v = Range(m.range(at: 2), in: t), let from = Range(m.range(at: 3), in: t),
              let value = Double(t[v].replacingOccurrences(of: ",", with: "")) else { return nil }
        let req = Request(value: value, from: t[from].lowercased().trimmingCharacters(in: .whitespaces),
                          to: t[to].lowercased().trimmingCharacters(in: .whitespaces))
        return (currencyPair(req) != nil || unitPair(req) != nil) ? req : nil
    }

    static func convert(_ req: Request) async -> String {
        if let (fromCode, toCode) = currencyPair(req) {
            return await currency(req.value, fromCode, toCode)
        }
        if let (fromUnit, toUnit) = unitPair(req) {
            let result = Measurement<Dimension>(value: req.value, unit: fromUnit).converted(to: toUnit).value
            return "\(format(req.value)) \(req.from) is about \(format(result)) \(req.to)."
        }
        return "I couldn't work out that conversion."
    }

    // MARK: Units

    private static let unitTable: [String: Dimension] = {
        var t: [String: Dimension] = [:]
        func add(_ names: [String], _ unit: Dimension) { names.forEach { t[$0] = unit } }
        add(["mile", "miles", "mi"], UnitLength.miles)
        add(["kilometer", "kilometers", "kilometre", "kilometres", "km", "kms"], UnitLength.kilometers)
        add(["meter", "meters", "metre", "metres", "m"], UnitLength.meters)
        add(["foot", "feet", "ft"], UnitLength.feet)
        add(["inch", "inches", "in"], UnitLength.inches)
        add(["yard", "yards", "yd", "yds"], UnitLength.yards)
        add(["centimeter", "centimeters", "centimetre", "centimetres", "cm"], UnitLength.centimeters)
        add(["pound", "pounds", "lb", "lbs"], UnitMass.pounds)
        add(["kilogram", "kilograms", "kilo", "kilos", "kg", "kgs"], UnitMass.kilograms)
        add(["ounce", "ounces", "oz"], UnitMass.ounces)
        add(["gram", "grams", "g"], UnitMass.grams)
        add(["stone", "stones"], UnitMass.stones)
        add(["fahrenheit", "f"], UnitTemperature.fahrenheit)
        add(["celsius", "centigrade", "c"], UnitTemperature.celsius)
        add(["kelvin", "k"], UnitTemperature.kelvin)
        add(["gallon", "gallons", "gal"], UnitVolume.gallons)
        add(["liter", "liters", "litre", "litres", "l"], UnitVolume.liters)
        add(["cup", "cups"], UnitVolume.cups)
        add(["tablespoon", "tablespoons", "tbsp"], UnitVolume.tablespoons)
        add(["teaspoon", "teaspoons", "tsp"], UnitVolume.teaspoons)
        add(["milliliter", "milliliters", "millilitre", "millilitres", "ml"], UnitVolume.milliliters)
        add(["fluid ounce", "fluid ounces", "fl oz"], UnitVolume.fluidOunces)
        add(["quart", "quarts"], UnitVolume.quarts)
        add(["pint", "pints"], UnitVolume.pints)
        add(["mph", "miles per hour", "miles an hour"], UnitSpeed.milesPerHour)
        add(["kph", "kmh", "km/h", "kilometers per hour", "kilometres per hour"], UnitSpeed.kilometersPerHour)
        add(["knot", "knots"], UnitSpeed.knots)
        add(["meters per second", "metres per second", "m/s"], UnitSpeed.metersPerSecond)
        return t
    }()

    private static func unitPair(_ r: Request) -> (Dimension, Dimension)? {
        guard let a = unitTable[r.from], let b = unitTable[r.to], type(of: a) == type(of: b) else { return nil }
        return (a, b)
    }

    // MARK: Currency

    private static let currencyNames: [(String, String)] = [
        ("canadian dollar", "CAD"), ("australian dollar", "AUD"), ("new zealand dollar", "NZD"), ("mexican peso", "MXN"),
        ("british pound", "GBP"), ("pound sterling", "GBP"), ("swiss franc", "CHF"), ("us dollar", "USD"), ("american dollar", "USD"),
        ("dollar", "USD"), ("buck", "USD"), ("euro", "EUR"), ("yen", "JPY"), ("peso", "MXN"), ("rupee", "INR"),
        ("yuan", "CNY"), ("renminbi", "CNY"), ("franc", "CHF"), ("won", "KRW"), ("real", "BRL"), ("reais", "BRL"),
        ("krona", "SEK"), ("kronor", "SEK"), ("zloty", "PLN"), ("shekel", "ILS"), ("rand", "ZAR"), ("baht", "THB"),
    ]
    private static let codeSpoken: [String: String] = [
        "USD": "US dollars", "EUR": "euros", "GBP": "British pounds", "JPY": "yen", "CAD": "Canadian dollars",
        "AUD": "Australian dollars", "NZD": "New Zealand dollars", "MXN": "Mexican pesos", "INR": "rupees",
        "CNY": "yuan", "CHF": "Swiss francs", "KRW": "won", "BRL": "reais", "SEK": "kronor", "PLN": "zloty",
        "ILS": "shekels", "ZAR": "rand", "THB": "baht",
    ]

    private static func code(_ name: String, other: String) -> String? {
        let n = name.lowercased()
        if n.count == 3, codeSpoken[n.uppercased()] != nil { return n.uppercased() }
        if n == "pound" || n == "pounds" { return unitTable[other] == nil || isCurrencyWord(other) ? "GBP" : nil }
        for (word, c) in currencyNames where n.hasPrefix(word) || n.contains(word) { return c }
        return nil
    }

    private static func isCurrencyWord(_ s: String) -> Bool {
        let n = s.lowercased()
        if n.count == 3, codeSpoken[n.uppercased()] != nil { return true }
        return currencyNames.contains { n.contains($0.0) }
    }

    private static func currencyPair(_ r: Request) -> (String, String)? {
        guard let a = code(r.from, other: r.to), let b = code(r.to, other: r.from), a != b else { return nil }
        // "pounds to kilograms" is weight, not money.
        if (r.from == "pound" || r.from == "pounds") && unitTable[r.to] != nil && !isCurrencyWord(r.to) { return nil }
        if (r.to == "pound" || r.to == "pounds") && unitTable[r.from] != nil && !isCurrencyWord(r.from) { return nil }
        return (a, b)
    }

    private static func currency(_ amount: Double, _ from: String, _ to: String) async -> String {
        var c = URLComponents(string: "https://api.frankfurter.app/latest")!
        c.queryItems = [.init(name: "amount", value: String(amount)), .init(name: "from", value: from), .init(name: "to", value: to)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = root["rates"] as? [String: Double], let result = rates[to] else {
            return "I couldn't get the exchange rate right now. Check your connection and try again."
        }
        let digits = to == "JPY" || to == "KRW" ? 0 : 2
        return "\(format(amount)) \(codeSpoken[from] ?? from) is about \(format(result, digits: digits)) \(codeSpoken[to] ?? to), at today's rate."
    }

    private static func format(_ v: Double, digits: Int = 2) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}


/// "Switch everything to metric" / "use Fahrenheit again": changes BOT's own units for weather, distances and answers.
enum UnitPreference {
    /// true = metric, false = US/imperial, nil = not a units request.
    static func parse(_ text: String) -> Bool? {
        let t = text.lowercased()
        if t.contains(where: { $0.isNumber }) { return nil }   // "convert 5 miles to kilometers" is a conversion
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        guard has(#"\b(?:switch|change|set|use|go|make)\b"#) else { return nil }
        let metric = has(#"\b(?:metric|celsius|centigrade|kilometers?|kilometres?)\b"#)
        let us = has(#"\b(?:imperial|fahrenheit|us units|u\.s\. units|american units|standard units|miles)\b"#)
        if metric == us { return nil }
        return metric
    }
}
