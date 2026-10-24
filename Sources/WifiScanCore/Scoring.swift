import Foundation

public struct ChannelLoad: Sendable, Identifiable {
    public let id: String
    public let channel: Int
    public let band: ScannedNetwork.Band
    public var primaryNetworks: [ScannedNetwork] = []
    public var overlapNetworks: [ScannedNetwork] = []
    public var adjacentNetworks: [ScannedNetwork] = []

    public init(channel: Int, band: ScannedNetwork.Band) {
        self.channel = channel
        self.band = band
        self.id = "\(band.rawValue)_\(channel)"
    }

    public var saturationScore: Double {
        let p = primaryNetworks.reduce(0.0) { $0 + Scoring.weight(rssi: $1.rssi) * Scoring.coChannelWeight }
        let o = overlapNetworks.reduce(0.0)  { $0 + Scoring.weight(rssi: $1.rssi) * Scoring.overlapWeight }
        let a = adjacentNetworks.reduce(0.0) { $0 + Scoring.weight(rssi: $1.rssi) * Scoring.adjacentWeight }
        return p + o + a
    }

    public var totalInterferers: Int {
        primaryNetworks.count + overlapNetworks.count + adjacentNetworks.count
    }
}

public enum Scoring {
    /// Sotto questa soglia, una rete non interferisce realisticamente (CCA).
    public static let rssiFloor: Int = -85

    public static let coChannelWeight: Double = 1.0
    public static let overlapWeight:   Double = 0.7
    public static let adjacentWeight:  Double = 0.3

    /// Curva RSSI → peso [0, 1]. -40 dBm → 1.0, -85 dBm → 0.0.
    public static func weight(rssi: Int) -> Double {
        if rssi < rssiFloor { return 0 }
        let clamped = min(-40, rssi)
        return Double(clamped - rssiFloor) / Double(-40 - rssiFloor)
    }
}

public enum SelfDetector {
    /// Identifica gli indici (in `networks`) delle reti che appartengono "probabilmente" all'AP dell'utente.
    public static func identifySelf(networks: [ScannedNetwork], connected: ConnectedNetwork) -> Set<Int> {
        var result = Set<Int>()

        // 1. SSID noto
        if let mySsid = connected.ssid, mySsid != "<nascosto>", !mySsid.isEmpty {
            for (i, n) in networks.enumerated() where n.ssid == mySsid {
                result.insert(i)
            }
            return result
        }

        // 2. BSSID noto e valido
        if let myBssid = connected.bssid?.lowercased(),
           myBssid.contains(":"), !myBssid.contains("?") {
            let myPrefix = String(myBssid.prefix(14))
            for (i, n) in networks.enumerated() {
                let nb = n.bssid.lowercased()
                if nb.contains("?") { continue }
                if nb == myBssid || nb.hasPrefix(myPrefix) {
                    result.insert(i)
                }
            }
            if !result.isEmpty { return result }
        }

        // 3. Solo canale noto → rete più forte sul nostro canale.
        if let myCh = connected.channel {
            let myBlock = ChannelAnalyzer.blockChannels(for: myCh)
            let candidates = networks.enumerated().filter { (_, n) in
                myBlock.contains(n.channel) && n.band != .ghz24
            }
            if let (idx, strongest) = candidates.max(by: { $0.element.rssi < $1.element.rssi }) {
                result.insert(idx)
                if strongest.ssid != "<nascosto>", !strongest.ssid.isEmpty {
                    for (i, n) in networks.enumerated() where n.ssid == strongest.ssid {
                        result.insert(i)
                    }
                }
            }
        }

        return result
    }
}

public final class ChannelAnalyzer: Sendable {
    public static let channels24: [Int] = Array(1...13)
    public static let channels5:  [Int] = [36, 40, 44, 48, 52, 56, 60, 64,
                                           100, 104, 108, 112, 116, 120, 124, 128,
                                           132, 136, 140, 144, 149, 153, 157, 161, 165]

    public init() {}

    public static func blockChannels(for channel: Int) -> Set<Int> {
        let blocks80: [[Int]] = [
            [36, 40, 44, 48], [52, 56, 60, 64],
            [100, 104, 108, 112], [116, 120, 124, 128],
            [132, 136, 140, 144], [149, 153, 157, 161]
        ]
        for b in blocks80 where b.contains(channel) { return Set(b) }
        return [channel]
    }

    public static func occupiedChannels(network n: ScannedNetwork) -> Set<Int> {
        switch n.band {
        case .ghz24:
            let radius = n.width == 40 ? 4 : 2
            return Set((n.channel - radius)...(n.channel + radius)).intersection(channels24)
        case .ghz5, .ghz6:
            if n.width == 80 { return blockChannels(for: n.channel) }
            if n.width == 160 {
                if (36...64).contains(n.channel)   { return Set([36,40,44,48,52,56,60,64]) }
                if (100...128).contains(n.channel) { return Set([100,104,108,112,116,120,124,128]) }
                return [n.channel]
            }
            if n.width == 40 {
                let other = (n.channel % 8 == 4) ? n.channel + 4 : n.channel - 4
                return Set([n.channel, other]).filter { $0 > 0 }
            }
            return [n.channel]
        }
    }

    /// Dedup: BSSID virtuali dello stesso AP fisico → tieni il più forte.
    public static func dedupVirtualAPs(_ networks: [ScannedNetwork]) -> [ScannedNetwork] {
        var byKey: [String: ScannedNetwork] = [:]
        for n in networks {
            let bssid = n.bssid.lowercased()
            let key: String
            if bssid.contains("?") || !bssid.contains(":") {
                let rssiBucket = (n.rssi + 2) / 5
                key = "\(n.ssid)_ch\(n.channel)_w\(n.width)_r\(rssiBucket)"
            } else {
                key = String(bssid.prefix(14)) + "_ch\(n.channel)_w\(n.width)"
            }
            if let existing = byKey[key] {
                if n.rssi > existing.rssi { byKey[key] = n }
            } else {
                byKey[key] = n
            }
        }
        return Array(byKey.values)
    }

    public func analyze(_ networks: [ScannedNetwork], excludingIndices: Set<Int> = []) -> [ChannelLoad] {
        let filtered = networks.enumerated().compactMap { (i, n) in
            excludingIndices.contains(i) ? nil : n
        }
        let deduped = Self.dedupVirtualAPs(filtered)

        var loads24: [Int: ChannelLoad] = [:]
        var loads5:  [Int: ChannelLoad] = [:]
        for ch in Self.channels24 { loads24[ch] = ChannelLoad(channel: ch, band: .ghz24) }
        for ch in Self.channels5  { loads5[ch]  = ChannelLoad(channel: ch, band: .ghz5)  }

        for n in deduped {
            let occupied = Self.occupiedChannels(network: n)
            switch n.band {
            case .ghz24:
                for ch in occupied {
                    if ch == n.channel {
                        loads24[ch]?.primaryNetworks.append(n)
                    } else {
                        loads24[ch]?.overlapNetworks.append(n)
                    }
                }
                for ch in Self.channels24 {
                    let delta = abs(ch - n.channel)
                    if delta >= 5 && delta <= 7 {
                        loads24[ch]?.adjacentNetworks.append(n)
                    }
                }
            case .ghz5, .ghz6:
                for ch in occupied {
                    if ch == n.channel {
                        loads5[ch]?.primaryNetworks.append(n)
                    } else {
                        loads5[ch]?.overlapNetworks.append(n)
                    }
                }
            }
        }

        let all = Array(loads24.values) + Array(loads5.values)
        return all.sorted { ($0.band.rawValue, $0.channel) < ($1.band.rawValue, $1.channel) }
    }
}

public enum ChannelClass: Sendable {
    case nonDFS, dfs, dfsTerminal

    public static func classify(_ channel: Int) -> ChannelClass {
        if (36...48).contains(channel) { return .nonDFS }
        if (149...165).contains(channel) { return .nonDFS }
        if [120, 124, 128].contains(channel) { return .dfsTerminal }
        return .dfs
    }

    public var label: String {
        switch self {
        case .nonDFS: return ""
        case .dfs: return "DFS"
        case .dfsTerminal: return "DFS weather"
        }
    }

    public var isNonDFS: Bool { self == .nonDFS }
}
