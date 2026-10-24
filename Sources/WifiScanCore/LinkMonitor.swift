import Foundation
import CoreWLAN

/// Stato istantaneo del collegamento Wi-Fi del Mac.
public struct LinkSnapshot: Sendable, Hashable {
    public let timestamp: Date
    public let ssid: String?
    public let bssid: String?
    public let rssi: Int              // dBm
    public let noise: Int             // dBm
    public let txRateMbps: Double
    public let txPowerMilliwatt: Int
    public let phyMode: String        // es. "802.11ax (Wi-Fi 6)"
    public let channel: Int?
    public let band: ScannedNetwork.Band?
    public let widthMHz: Int?
    public let security: String       // es. "WPA3 Personal"
    public var snr: Int { rssi - noise }

    public init(timestamp: Date, ssid: String?, bssid: String?, rssi: Int, noise: Int,
                txRateMbps: Double, txPowerMilliwatt: Int, phyMode: String, channel: Int?,
                band: ScannedNetwork.Band?, widthMHz: Int?, security: String) {
        self.timestamp = timestamp
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.txRateMbps = txRateMbps
        self.txPowerMilliwatt = txPowerMilliwatt
        self.phyMode = phyMode
        self.channel = channel
        self.band = band
        self.widthMHz = widthMHz
        self.security = security
    }
}

public enum LinkQuality: String, Sendable {
    case excellent = "Ottimo", good = "Buono", fair = "Discreto", poor = "Scarso"
}

public enum LinkMonitor {
    /// Legge l'interfaccia Wi-Fi corrente. nil se non connesso (rssi == 0 o nessuna interfaccia).
    public static func snapshot() -> LinkSnapshot? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        let rssi = iface.rssiValue()
        guard rssi != 0 else { return nil }
        let channel = iface.wlanChannel()
        return LinkSnapshot(
            timestamp: Date(),
            ssid: iface.ssid(),
            bssid: iface.bssid(),
            rssi: rssi,
            noise: iface.noiseMeasurement(),
            txRateMbps: iface.transmitRate(),
            txPowerMilliwatt: iface.transmitPower(),
            phyMode: phyModeLabel(iface.activePHYMode()),
            channel: channel?.channelNumber,
            band: channel.flatMap(band(of:)),
            widthMHz: channel.map(width(of:)),
            security: securityLabel(iface.security())
        )
    }

    public static func phyModeLabel(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n (Wi-Fi 4)"
        case .mode11ac: return "802.11ac (Wi-Fi 5)"
        case .mode11ax: return "802.11ax (Wi-Fi 6)"
        default: return "Sconosciuto"
        }
    }

    public static func securityLabel(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "Aperta"
        case .WEP: return "WEP"
        case .dynamicWEP: return "WEP dinamico"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .enterprise: return "Enterprise"
        case .unknown: return "Sconosciuta"
        default: return "Sconosciuta"
        }
    }

    /// SNR ≥ 40 ottimo, ≥ 25 buono, ≥ 15 discreto, altrimenti scarso.
    public static func quality(snr: Int) -> LinkQuality {
        if snr >= 40 { return .excellent }
        if snr >= 25 { return .good }
        if snr >= 15 { return .fair }
        return .poor
    }

    // Stessa mappatura di WiFiScanner.convert (Scanner.swift), con banda nil se sconosciuta.
    private static func band(of ch: CWChannel) -> ScannedNetwork.Band? {
        switch ch.channelBand {
        case .band2GHz: return .ghz24
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        case .bandUnknown: return nil
        @unknown default: return nil
        }
    }

    private static func width(of ch: CWChannel) -> Int {
        switch ch.channelWidth {
        case .width20MHz: return 20
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        case .widthUnknown: return 20
        @unknown default: return 20
        }
    }
}
