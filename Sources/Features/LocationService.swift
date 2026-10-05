import Foundation
import CoreLocation
import MapKit

struct NearbyPlace {
    var name: String
    var miles: Double
    var phone: String?
    var coordinate: CLLocationCoordinate2D
}

/// Shared current-location + Apple Maps helpers (nearby search, drive-time estimates). Free, no API key.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var waiter: CheckedContinuation<CLLocation?, Never>?
    private var waitingForAuth = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: Current location

    func current() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            waitingForAuth = true
            manager.requestWhenInUseAuthorization()
        default:
            if let cached = manager.location, abs(cached.timestamp.timeIntervalSinceNow) < 300 { return cached }
        }
        return await withCheckedContinuation { cont in
            waiter = cont
            if !waitingForAuth { manager.requestLocation() }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self?.resolve(nil)
            }
        }
    }

    private func resolve(_ loc: CLLocation?) {
        let w = waiter
        waiter = nil
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

    // MARK: Maps

    /// Closest matches for "coffee shop", "pharmacy", etc. around `location`.
    func nearby(_ query: String, around location: CLLocation) async -> [NearbyPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let places: [NearbyPlace] = response.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            let coordinate = item.placemark.coordinate
            let meters = location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            return NearbyPlace(name: name, miles: meters / 1609.34, phone: item.phoneNumber, coordinate: coordinate)
        }
        return Array(places.sorted { $0.miles < $1.miles }.prefix(3))
    }

    /// Estimated drive time in minutes, using live traffic where Apple Maps has it.
    func driveMinutes(from: CLLocation, to destination: CLLocationCoordinate2D, departure: Date) async -> Int? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.departureDate = max(departure, Date())
        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
        return max(1, Int((eta.expectedTravelTime / 60).rounded()))
    }

    /// "Main Street" / "Union Station", for saving a parking spot.
    func describe(_ location: CLLocation) async -> String {
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return "where you are" }
        if let street = mark.thoroughfare {
            return [mark.subThoroughfare, street].compactMap { $0 }.joined(separator: " ")
        }
        return mark.name ?? mark.locality ?? "where you are"
    }

    func geocode(_ address: String) async -> CLLocationCoordinate2D? {
        let marks = try? await CLGeocoder().geocodeAddressString(address)
        return marks?.first?.location?.coordinate
    }
}
