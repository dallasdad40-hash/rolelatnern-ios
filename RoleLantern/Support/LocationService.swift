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
    /// The device's country as the job board stores it ("US", "UK", "Canada"...).
    /// Starts from the phone's region setting and is replaced by the real location.
    @Published var boardCountry: String? = LocationService.boardCountry(forISO: Locale.current.region?.identifier)

    private var retries = 0

    /// Job board country names: "US" and "UK" are short codes, the rest are English names.
    static func boardCountry(forISO code: String?) -> String? {
        guard let code = code?.uppercased(), !code.isEmpty else { return nil }
        switch code {
        case "US": return "US"
        case "GB": return "UK"
        default: return Locale(identifier: "en_US").localizedString(forRegionCode: code)
        }
    }

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
            publishCachedLocation()
            manager.requestLocation()
        }
    }

    /// Use the last known fix right away (if recent) so the board doesn't wait.
    private func publishCachedLocation() {
        guard latitude == nil, let loc = manager.location,
              abs(loc.timestamp.timeIntervalSinceNow) < 6 * 3600 else { return }
        handle(loc)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            publishCachedLocation()
            manager.requestLocation()
        case .denied, .restricted:
            DispatchQueue.main.async { self.denied = true }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        retries = 0
        handle(loc)
    }

    private func handle(_ loc: CLLocation) {
        let coord = loc.coordinate
        DispatchQueue.main.async {
            self.latitude = coord.latitude
            self.longitude = coord.longitude
        }
        geocoder.reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { [weak self] marks, _ in
            guard let mark = marks?.first else { return }
            let parts = [mark.locality, mark.administrativeArea].compactMap { $0 }
            let country = LocationService.boardCountry(forISO: mark.isoCountryCode)
            DispatchQueue.main.async {
                self?.placeName = parts.isEmpty ? nil : parts.joined(separator: ", ")
                if let country { self?.boardCountry = country }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A first fix often fails right after launch: try again a few times.
        guard retries < 3 else { return }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.manager.requestLocation()
        }
    }
}
