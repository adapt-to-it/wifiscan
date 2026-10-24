import Foundation
import CoreLocation
import Observation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.marcoabbattista.wifiscanner", category: "LocationAuth")

/// Gestisce il prompt Location richiesto da macOS per leggere SSID/BSSID via CoreWLAN.
///
/// Il prompt appare solo:
/// - dentro un'app bundle .app firmata con Developer ID
/// - con NSLocationWhenInUseUsageDescription nell'Info.plist
/// - quando la sessione utente è attiva (no spawned CLI senza UI)
@MainActor
@Observable
final class LocationAuthorizationModel: NSObject {
    private let manager = CLLocationManager()
    var status: CLAuthorizationStatus

    override init() {
        self.status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        logger.info("Initial Location auth status: \(self.status.rawValue, privacy: .public) (\(String(describing: self.status), privacy: .public))")
    }

    /// Triggera il prompt se notDetermined. Idempotente: no-op se già concesso o negato.
    /// macOS supporta solo `requestAlwaysAuthorization` (non WhenInUse).
    func requestIfNeeded() {
        logger.info("requestIfNeeded called, current status: \(self.status.rawValue, privacy: .public)")
        guard status == .notDetermined else {
            logger.info("Skipping request: not in notDetermined state")
            return
        }
        manager.requestAlwaysAuthorization()
    }

    /// True quando l'app ha permessi sufficienti per SSID/BSSID reali.
    /// macOS espone solo `.authorizedAlways` (non `.authorizedWhenInUse`).
    var isAuthorized: Bool {
        status == .authorizedAlways
    }

    /// True quando il prompt non è ancora stato mostrato.
    var isPending: Bool { status == .notDetermined }

    /// True se l'utente o il sistema ha negato i permessi.
    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    var statusDescription: String {
        switch status {
        case .notDetermined: return "Non richiesto"
        case .denied: return "Negato"
        case .restricted: return "Limitato"
        case .authorizedAlways: return "Concesso"
        @unknown default: return "Sconosciuto"
        }
    }

    /// Apre il pannello Privacy → Location nelle Impostazioni di Sistema.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension LocationAuthorizationModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.status = newStatus
        }
    }
}
