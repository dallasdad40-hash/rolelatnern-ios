import Foundation
import CoreLocation

/// One-shot, coarse device location for the "Near me" job filter.
/// Coordinates are used to build a search area; nothing is stored server-side.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var latitude: Double?
    @Published var longitude: Double?
    @Published var denied = false
    /// e.g. "McKinney, TX" for the header on the job board.
    @Published var placeName: String?

    private let geocoder = CLGeocoder()

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            DispatchQueue.main.async { self.denied = true }
        default:
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            DispatchQueue.main.async { self.denied = true }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.first?.coordinate else { return }
        DispatchQueue.main.async {
            self.latitude = coord.latitude
            self.longitude = coord.longitude
        }
        geocoder.reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { [weak self] marks, _ in
            guard let mark = marks?.first else { return }
            let parts = [mark.locality, mark.administrativeArea].compactMap { $0 }
            DispatchQueue.main.async { self?.placeName = parts.isEmpty ? nil : parts.joined(separator: ", ") }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Leave coordinates unset; the filter simply won't constrain.
    }
}
