import Foundation

public struct ScannedNetwork: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let ssid: String
    public let bssid: String
    public let rssi: Int          // dBm
    public let noise: Int         // dBm
    public let channel: Int
    public let band: Band
    public let width: Int         // MHz: 20, 40, 80, 160
    public let beacon: BeaconInfo?  // Information Element; nil senza Location

    public enum Band: String, Sendable, Hashable, CaseIterable {
        case ghz24 = "2.4 GHz"
        case ghz5 = "5 GHz"
        case ghz6 = "6 GHz"
    }

    public var snr: Int { rssi - noise }

    public init(ssid: String, bssid: String, rssi: Int, noise: Int,
                channel: Int, band: Band, width: Int, beacon: BeaconInfo? = nil) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.band = band
        self.width = width
        self.beacon = beacon
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: ScannedNetwork, rhs: ScannedNetwork) -> Bool { lhs.id == rhs.id }
}

/// Rete corrente identificata (manuale o automatica).
public struct ConnectedNetwork: Sendable {
    public let channel: Int?
    public let bssid: String?
    public let ssid: String?

    public init(channel: Int? = nil, bssid: String? = nil, ssid: String? = nil) {
        self.channel = channel
        self.bssid = bssid
        self.ssid = ssid
    }
}

/// Risultato completo di una scansione + analisi.
public struct ScanResult: Sendable {
    public let timestamp: Date
    public let networks: [ScannedNetwork]
    public let loads: [ChannelLoad]
    public let selfIndices: Set<Int>
    public let connected: ConnectedNetwork?

    public init(timestamp: Date, networks: [ScannedNetwork], loads: [ChannelLoad],
                selfIndices: Set<Int>, connected: ConnectedNetwork?) {
        self.timestamp = timestamp
        self.networks = networks
        self.loads = loads
        self.selfIndices = selfIndices
        self.connected = connected
    }
}
