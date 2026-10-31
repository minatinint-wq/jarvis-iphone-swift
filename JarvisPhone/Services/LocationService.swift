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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateAuthorization() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last else { return }
        finish(.success(value.coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }
}
