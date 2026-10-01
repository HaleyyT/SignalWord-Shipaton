import CoreLocation
import Foundation



/// Owns Core Location on the main actor. It exposes an immediate cached sample
/// for the critical alert request and a best-effort fresh sample for a later
/// location update. Neither path can prevent the alert itself from being sent.
@MainActor
final class LiveLocationService: NSObject, AlertLocationProviding, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pendingSnapshot: (id: UUID, continuation: CheckedContinuation<AlertLocationSnapshot?, Never>)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorization: DeviceLocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined:
            return .notRequested
        case .authorizedAlways, .authorizedWhenInUse:
            return manager.accuracyAuthorization == .fullAccuracy ? .precise : .approximate
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAccess() async -> DeviceLocationAuthorization {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            for _ in 0..<120 where manager.authorizationStatus == .notDetermined {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            _ = await requestFreshSnapshot(timeout: .seconds(8))
        }
        return authorization
    }

    func cachedSnapshot(at now: Date) async -> AlertLocationSnapshot? {
        guard let location = manager.location else { return nil }
        let snapshot = Self.snapshot(from: location)
        return snapshot.isUsable(at: now) ? snapshot : nil
    }

    func requestFreshSnapshot(timeout: Duration) async -> AlertLocationSnapshot? {
        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse else { return nil }

        pendingSnapshot?.continuation.resume(returning: nil)
        pendingSnapshot = nil
        return await withCheckedContinuation { continuation in
            let requestID = UUID()
            pendingSnapshot = (requestID, continuation)
            manager.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let pending = self.pendingSnapshot,
                      pending.id == requestID else { return }
                self.pendingSnapshot = nil
                pending.continuation.resume(returning: nil)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let pending = pendingSnapshot else { return }
        pendingSnapshot = nil
        let now = Date()
        let snapshot = locations.last.map(Self.snapshot(from:))
        pending.continuation.resume(returning: snapshot?.isUsable(at: now) == true ? snapshot : nil)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard let pending = pendingSnapshot else { return }
        pendingSnapshot = nil
        pending.continuation.resume(returning: nil)
    }

    private static func snapshot(from location: CLLocation) -> AlertLocationSnapshot {
        AlertLocationSnapshot(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracyM: location.horizontalAccuracy,
            capturedAt: location.timestamp
        )
    }
}
