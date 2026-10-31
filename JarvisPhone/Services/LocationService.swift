import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentCoordinate() async throws -> CLLocationCoordinate2D {
        guard CLLocationManager.locationServicesEnabled() else {
            throw PhoneCommandError.permission("Ative os Serviços de Localização nos Ajustes.")
        }
        guard pending == nil else {
            throw PhoneCommandError.unavailable("Já existe uma consulta de localização em andamento.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
                self?.finish(.failure(PhoneCommandError.unavailable("A localização demorou a responder. Tente novamente.")))
            }
            updateAuthorization()
        }
    }

    private func updateAuthorization() {
        guard pending != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(PhoneCommandError.permission("Permita localização durante o uso em Ajustes → JARVIS XLV.")))
        @unknown default:
            finish(.failure(PhoneCommandError.unavailable("Autorização de localização não reconhecida.")))
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        let continuation = pending
        pending = nil
        timeout?.cancel()
        timeout = nil
        continuation?.resume(with: result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.updateAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last else { return }
        let latitude = value.coordinate.latitude
        let longitude = value.coordinate.longitude
        Task { @MainActor [weak self] in
            self?.finish(.success(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.finish(.failure(PhoneCommandError.unavailable(message)))
        }
    }
}
