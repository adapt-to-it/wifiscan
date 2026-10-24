import Foundation
import CoreWLAN

public final class WiFiScanner: @unchecked Sendable {
    public let client = CWWiFiClient.shared()
    public var interface: CWInterface? { client.interface() }

    public init() {}

    public func scan() throws -> [ScannedNetwork] {
        guard let iface = interface else {
            throw NSError(domain: "wifiscan", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Nessuna interfaccia Wi-Fi trovata"])
        }
        // La scansione porta la radio fuori canale: il monitor scarta i ping di questo intervallo.
        let activity = AppActivityLog.shared.begin(.wifiScan)
        defer { AppActivityLog.shared.end(activity) }
        // Le reti nascoste occupano comunque il canale: servono allo scoring.
        let fresh = try iface.scanForNetworks(withName: nil, includeHidden: true)
        // Un singolo passaggio perde beacon, soprattutto a 2.4 GHz (dwell breve per canale).
        // La cache di sistema accumula gli scan recenti: la uniamo, a parità di BSSID vince il fresco.
        let cached = iface.cachedScanResults() ?? []
        let freshBssids = Set(fresh.compactMap(\.bssid))
        let merged: [CWNetwork]
        if freshBssids.isEmpty {
            // Senza Location i BSSID sono nil e non si può deduplicare: prendiamo l'insieme più completo.
            merged = Array(cached.count > fresh.count ? cached : fresh)
        } else {
            merged = Array(fresh) + cached.filter { $0.bssid.map { !freshBssids.contains($0) } ?? false }
        }
        return merged.compactMap { Self.convert($0) }
    }

    /// Reti dell'ultimo scan eseguito dal sistema. Istantaneo, nessuno scan radio.
    public func cachedScan() -> [ScannedNetwork] {
        interface?.cachedScanResults()?.compactMap { Self.convert($0) } ?? []
    }

    /// Canale corrente. Funziona senza Location.
    public func currentChannel() -> Int? {
        interface?.wlanChannel()?.channelNumber
    }

    /// BSSID corrente. Su macOS recente è nil senza Location.
    public func currentBssid() -> String? {
        interface?.bssid()
    }

    /// SSID corrente. Su macOS recente è nil senza Location.
    public func currentSsid() -> String? {
        interface?.ssid()
    }

    public func interfaceName() -> String? {
        interface?.interfaceName
    }

    public func countryCode() -> String? {
        interface?.countryCode()
    }

    private static func convert(_ n: CWNetwork) -> ScannedNetwork? {
        guard let ch = n.wlanChannel else { return nil }
        let band: ScannedNetwork.Band
        switch ch.channelBand {
        case .band2GHz: band = .ghz24
        case .band5GHz: band = .ghz5
        case .band6GHz: band = .ghz6
        case .bandUnknown: return nil
        @unknown default: return nil
        }
        let width: Int
        switch ch.channelWidth {
        case .width20MHz:  width = 20
        case .width40MHz:  width = 40
        case .width80MHz:  width = 80
        case .width160MHz: width = 160
        case .widthUnknown: width = 20
        @unknown default:  width = 20
        }
        return ScannedNetwork(
            ssid: n.ssid ?? "<nascosto>",
            bssid: n.bssid ?? "??",
            rssi: n.rssiValue,
            noise: n.noiseMeasurement,
            channel: ch.channelNumber,
            band: band,
            width: width,
            beacon: InformationElements.parse(n.informationElementData)
        )
    }
}
