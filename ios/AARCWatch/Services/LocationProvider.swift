import Foundation
import CoreLocation

/// Watch-side wrapper around `CLLocationManager` configured for running.
/// Apple's running activity type + workout context handles smoothing and
/// accuracy filtering — we just receive the samples and forward them to
/// the route builder. We do NOT compute distance or pace from these
/// samples; that is `HKLiveWorkoutBuilder`'s job.
final class LocationProvider: NSObject, @unchecked Sendable {
    private let manager: CLLocationManager
    private let onLocations: @Sendable ([CLLocation]) -> Void

    init(onLocations: @Sendable @escaping ([CLLocation]) -> Void) {
        self.manager = CLLocationManager()
        self.onLocations = onLocations
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        requestAuthorizationIfNeeded()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension LocationProvider: @preconcurrency CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations(locations)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent for now; surface in UI in a later phase if it becomes visible.
    }
}
