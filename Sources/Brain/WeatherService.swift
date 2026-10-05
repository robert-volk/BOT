import Foundation
import CoreLocation

enum LookupResult {
    case ok(spoken: String, facts: String)
    case failed(String)
}

/// Live weather from Open-Meteo (free, no API key, no account). Uses your location when you ask
/// "what's the weather?" and geocodes a place name for "weather in Paris".
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationWaiter: CheckedContinuation<CLLocation?, Never>?
    private var waitingForAuth = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: Intent

    static func isWeatherQuestion(_ text: String) -> Bool {
        let pattern = #"\b(weather|forecast|temperature|umbrella)\b|\b(rain|raining|snow|snowing)\b.*\b(today|tonight|tomorrow|outside|going|will)\b|\bwill it (rain|snow)\b|\bhow (hot|cold|warm) is it\b|\bis it (raining|snowing|cold|hot|warm)\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func placeName(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"\b(?:in|for|at)\s+([A-Z][A-Za-z.'-]*(?:[ ,]+[A-Z][A-Za-z.'-]*)*)"#) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        var place = ns.substring(with: m.range(at: 1))
        for tail in ["Today", "Tomorrow", "Tonight", "Now"] where place.hasSuffix(" " + tail) {
            place = String(place.dropLast(tail.count + 1))
        }
        place = place.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        return place.isEmpty ? nil : place
    }

    // MARK: Lookup

    func report(for utterance: String, metric: Bool = false) async -> LookupResult {
        var lat = 0.0, lon = 0.0, label = "your area"

        if let place = Self.placeName(in: utterance) {
            guard let g = await geocode(place) else { return .failed("I couldn't find a place called \(place).") }
            (lat, lon, label) = g
        } else {
            guard let loc = await currentLocation() else {
                return .failed("I need location access to check your local weather. You can turn it on in Settings, or ask about a city, like weather in Chicago.")
            }
            lat = loc.coordinate.latitude
            lon = loc.coordinate.longitude
            label = await localityName(for: loc) ?? "your area"
        }

        let wantsTomorrow = utterance.lowercased().contains("tomorrow")
        do {
            return try await fetchForecast(lat: lat, lon: lon, label: label, tomorrow: wantsTomorrow, metric: metric)
        } catch {
            return .failed("I couldn't reach the weather service right now. Check your connection and try again.")
        }
    }

    struct DayForecast: Identifiable {
        let id = UUID()
        let date: Date
        let high: Double
        let low: Double
        let rain: Double
    }

    /// Seven days of highs, lows and chance of precipitation, for the forecast chart.
    func forecastSeries(lat: Double, lon: Double, metric: Bool) async -> [DayForecast] {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: metric ? "celsius" : "fahrenheit"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let times = daily["time"] as? [String],
              let highs = daily["temperature_2m_max"] as? [Double],
              let lows = daily["temperature_2m_min"] as? [Double] else { return [] }
        let rain = daily["precipitation_probability_max"] as? [Double] ?? []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var out: [DayForecast] = []
        for (i, t) in times.enumerated() {
            guard i < highs.count, i < lows.count, let d = formatter.date(from: t) else { continue }
            out.append(DayForecast(date: d, high: highs[i], low: lows[i], rain: i < rain.count ? rain[i] : 0))
        }
        return out
    }

    private func fetchForecast(lat: Double, lon: Double, label: String, tomorrow: Bool, metric: Bool) async throws -> LookupResult {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: metric ? "celsius" : "fahrenheit"),
            .init(name: "wind_speed_unit", value: metric ? "kmh" : "mph"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = root["current"] as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let temp = cur["temperature_2m"] as? Double else { throw URLError(.cannotParseResponse) }

        let feels = cur["apparent_temperature"] as? Double ?? temp
        let wind = cur["wind_speed_10m"] as? Double ?? 0
        let code = cur["weather_code"] as? Int ?? 0
        let highs = daily["temperature_2m_max"] as? [Double] ?? []
        let lows = daily["temperature_2m_min"] as? [Double] ?? []
        let rain = daily["precipitation_probability_max"] as? [Double] ?? []
        let codes = daily["weather_code"] as? [Int] ?? []

        func day(_ i: Int) -> String {
            guard i < highs.count, i < lows.count else { return "" }
            let r = i < rain.count ? Int(rain[i]) : 0
            let cond = i < codes.count ? Self.describe(codes[i]) : ""
            return "\(cond), high \(Int(highs[i].rounded())), low \(Int(lows[i].rounded())), \(r) percent chance of precipitation"
        }

        let windUnit = metric ? "km/h" : "mph"
        let calmLimit = metric ? 10.0 : 6.0, lightLimit = metric ? 24.0 : 15.0, breezyLimit = metric ? 40.0 : 25.0
        let windText = wind < calmLimit ? "calm" : (wind < lightLimit ? "a light breeze" : (wind < breezyLimit ? "a breezy \(Int(wind)) \(windUnit) wind" : "strong wind around \(Int(wind)) \(windUnit)"))
        let facts = "Live weather for \(label) (\(metric ? "Celsius, km/h" : "Fahrenheit, mph")): right now \(Int(temp.rounded())) degrees, feels like \(Int(feels.rounded())), \(Self.describe(code)), \(windText). Today: \(day(0)). Tomorrow: \(day(1))."

        var spoken = "Right now in \(label) it's \(Int(temp.rounded())) degrees and \(Self.describe(code))"
        spoken += abs(feels - temp) >= 4 ? ", feeling like \(Int(feels.rounded()))" : ""
        spoken += ", with \(windText). "
        if tomorrow, highs.count > 1 {
            spoken += "Tomorrow looks \(Self.describe(codes.count > 1 ? codes[1] : 0)), with a high of \(Int(highs[1].rounded())) and a low of \(Int(lows[1].rounded()))"
            spoken += rain.count > 1 && rain[1] >= 20 ? ", and a \(Int(rain[1])) percent chance of rain." : "."
        } else if let h = highs.first, let l = lows.first {
            spoken += "Today's high is \(Int(h.rounded())) and the low is \(Int(l.rounded()))"
            spoken += rain.first.map { $0 >= 20 ? ", with a \(Int($0)) percent chance of rain." : "." } ?? "."
        }
        return .ok(spoken: spoken, facts: facts)
    }

    private static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55, 56, 57: return "drizzly"
        case 61, 63, 65, 66, 67: return "rainy"
        case 71, 73, 75, 77: return "snowy"
        case 80, 81, 82: return "showery"
        case 85, 86: return "snowy"
        case 95, 96, 99: return "stormy"
        default: return "mixed"
        }
    }

    // MARK: Geocoding

    private func geocode(_ place: String) async -> (Double, Double, String)? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        // Open-Meteo matches the city name only, so drop anything after a comma.
        let city = place.split(separator: ",").first.map(String.init) ?? place
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: "en")]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return nil }
        let name = first["name"] as? String ?? city
        let region = first["admin1"] as? String
        return (lat, lon, [name, region].compactMap { $0 }.joined(separator: ", "))
    }

    private func localityName(for loc: CLLocation) async -> String? {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return nil }
        return p.locality ?? p.subAdministrativeArea
    }

    // MARK: Location

    private func currentLocation() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            waitingForAuth = true
            manager.requestWhenInUseAuthorization()
        default:
            if let cached = manager.location, abs(cached.timestamp.timeIntervalSinceNow) < 600 { return cached }
        }
        return await withCheckedContinuation { cont in
            locationWaiter = cont
            if !waitingForAuth { manager.requestLocation() }
            // Never hang the conversation on a location fix.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self?.resolve(nil)
            }
        }
    }

    private func resolve(_ loc: CLLocation?) {
        let w = locationWaiter
        locationWaiter = nil
        w?.resume(returning: loc)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.waitingForAuth else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.waitingForAuth = false
                manager.requestLocation()
            case .denied, .restricted:
                self.waitingForAuth = false
                self.resolve(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let first = locations.first
        Task { @MainActor in self.resolve(first) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolve(nil) }
    }
}
