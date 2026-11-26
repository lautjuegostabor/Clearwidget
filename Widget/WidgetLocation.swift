import Foundation
#if os(iOS)
import CoreLocation

// One short request when WidgetKit asks for a timeline, not continuous tracking.
@MainActor
private final class LocationRequest: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<WeatherLocation?, Never>?
    func read() async -> WeatherLocation? {
        guard manager.isAuthorizedForWidgetUpdates else { return nil }
        if let location = manager.location, let p = validated(location) { return p }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.startUpdatingLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.complete(nil)
            }
        }
    }
    private func validated(_ location: CLLocation) -> WeatherLocation? {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 20_000,
              abs(location.timestamp.timeIntervalSinceNow) < 300 else { return nil }
        let p = WeatherLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, observedAt: location.timestamp)
        return p.valid ? p : nil
    }
    private func complete(_ p: WeatherLocation?) {
        manager.stopUpdatingLocation()
        manager.delegate = nil
        let c = continuation
        continuation = nil
        c?.resume(returning: p)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let p = locations.last.flatMap(validated) { complete(p) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { complete(nil) }
}

enum WidgetLocation {
    @MainActor static func current() async -> WeatherLocation? {
        let request = LocationRequest()
        return await request.read()
    }
}
#else
enum WidgetLocation {
    static func current() async -> WeatherLocation? { nil }
}
#endif
