import Foundation

/// Dati estratti dagli Information Element del beacon di un AP.
public struct BeaconInfo: Sendable, Hashable {
    public var stationCount: Int?            // BSS Load
    public var channelUtilization: Double?   // BSS Load, 0...1
    public var wifiGeneration: Int?          // 4 HT, 5 VHT, 6 HE, 7 EHT
    public var security: [String] = []      // es. ["WPA2-PSK", "WPA3-SAE"]; vuoto = aperta o WEP
    public var hasTKIP = false
    public var wps = false
    public var supports11k = false
    public var supports11v = false
    public var supports11r = false
    public init() {}
}

public enum InformationElements {
    private static let wifiOUI: [UInt8] = [0x00, 0x0F, 0xAC]
    private static let microsoftOUI: [UInt8] = [0x00, 0x50, 0xF2]

    private static let akmNames: [UInt8: String] = [
        1: "802.1X",
        2: "WPA2-PSK",
        8: "WPA3-SAE",
        18: "OWE",
    ]

    /// nil se `data` è nil o vuoto.
    public static func parse(_ data: Data?) -> BeaconInfo? {
        guard let data = data, !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        var info = BeaconInfo()
        var i = 0
        while i + 2 <= bytes.count {
            let id = bytes[i]
            let len = Int(bytes[i + 1])
            let start = i + 2
            guard start + len <= bytes.count else { break } // lunghezza troncata
            apply(id: id, payload: Array(bytes[start..<start + len]), to: &info)
            i = start + len
        }
        return info
    }

    private static func apply(id: UInt8, payload p: [UInt8], to info: inout BeaconInfo) {
        switch id {
        case 11: // BSS Load
            guard p.count >= 3 else { return }
            info.stationCount = Int(p[0]) | (Int(p[1]) << 8)
            info.channelUtilization = Double(p[2]) / 255
        case 45: // HT Capabilities
            raiseGeneration(&info, 4)
        case 191: // VHT Capabilities
            raiseGeneration(&info, 5)
        case 255: // Extension element
            guard let ext = p.first else { return }
            switch ext {
            case 35: raiseGeneration(&info, 6)  // HE Capabilities
            case 108: raiseGeneration(&info, 7) // EHT Capabilities
            default: return
            }
        case 48: // RSN
            parseRSN(p, into: &info)
        case 221: // Vendor specific
            parseVendor(p, into: &info)
        case 70: // RM Enabled Capabilities
            info.supports11k = true
        case 54: // Mobility Domain
            info.supports11r = true
        case 127: // Extended Capabilities
            guard p.count >= 3 else { return }
            if ((p[2] >> 3) & 1) == 1 { info.supports11v = true } // bit 19
        default:
            return
        }
    }

    private static func raiseGeneration(_ info: inout BeaconInfo, _ gen: Int) {
        info.wifiGeneration = max(info.wifiGeneration ?? 0, gen)
    }

    /// RSN: version(2) group(4) pairwise count(2) + lista(4 cad.) AKM count(2) + lista(4 cad.).
    /// Le liste si fermano alla prima voce non completa.
    private static func parseRSN(_ p: [UInt8], into info: inout BeaconInfo) {
        guard p.count >= 8 else { return }
        if hasOUI(p, at: 2, wifiOUI), p[5] == 2 { info.hasTKIP = true } // group cipher TKIP

        let pairwiseCount = Int(p[6]) | (Int(p[7]) << 8)
        var off = 8
        for _ in 0..<pairwiseCount {
            guard off + 4 <= p.count else { return }
            if hasOUI(p, at: off, wifiOUI), p[off + 3] == 2 { info.hasTKIP = true }
            off += 4
        }

        guard off + 2 <= p.count else { return }
        let akmCount = Int(p[off]) | (Int(p[off + 1]) << 8)
        off += 2
        for _ in 0..<akmCount {
            guard off + 4 <= p.count else { return }
            if hasOUI(p, at: off, wifiOUI),
               let name = akmNames[p[off + 3]],
               !info.security.contains(name) {
                info.security.append(name)
            }
            off += 4
        }
    }

    /// Vendor 00-50-F2: tipo 1 = WPA, tipo 4 = WPS.
    private static func parseVendor(_ p: [UInt8], into info: inout BeaconInfo) {
        guard p.count >= 4, hasOUI(p, at: 0, microsoftOUI) else { return }
        switch p[3] {
        case 1:
            if !info.security.contains("WPA") { info.security.append("WPA") }
        case 4:
            info.wps = true
        default:
            return
        }
    }

    private static func hasOUI(_ p: [UInt8], at off: Int, _ oui: [UInt8]) -> Bool {
        off + 3 <= p.count && Array(p[off..<off + 3]) == oui
    }
}
