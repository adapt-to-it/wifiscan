import Foundation

public struct NetworkAlert: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case gatewayMACChanged, gatewayMACDuplicated, ipConflict, newDevice }
    public enum Severity: Int, Sendable, Comparable {
        case info, warning, critical
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public let id: String
    public let kind: Kind
    public let severity: Severity
    public let title: String
    public let detail: String
}

/// Coppia IP-MAC letta dalla cache ARP in un momento dello scan.
public struct ARPObservation: Sendable, Hashable {
    public let ip: String
    public let mac: String
    public init(ip: String, mac: String) { self.ip = ip; self.mac = mac }
}

public enum NetworkAlertDetector {
    public static func evaluate(observations: [ARPObservation], devices: [LanDevice],
                                gatewayIP: String?, previousGatewayMAC: String?) -> [NetworkAlert] {
        var alerts: [NetworkAlert] = []

        // Regole gateway: solo se il gateway è noto e compare nelle osservazioni.
        if let gatewayIP = gatewayIP,
           let gatewayMAC = observations.last(where: { $0.ip == gatewayIP })?.mac.lowercased() {
            if let previous = previousGatewayMAC?.lowercased(), previous != gatewayMAC {
                alerts.append(NetworkAlert(
                    id: "gatewayMACChanged-\(gatewayIP)", kind: .gatewayMACChanged, severity: .critical,
                    title: "MAC del gateway cambiato",
                    detail: "Il gateway \(gatewayIP) risponde con \(gatewayMAC), prima era \(previous)."))
            }
            let otherIPs = Set(observations
                .filter { $0.mac.lowercased() == gatewayMAC && $0.ip != gatewayIP }
                .map { $0.ip }).sorted()
            if !otherIPs.isEmpty {
                alerts.append(NetworkAlert(
                    id: "gatewayMACDuplicated-\(gatewayIP)", kind: .gatewayMACDuplicated, severity: .critical,
                    title: "MAC del gateway duplicato",
                    detail: "Il MAC \(gatewayMAC) del gateway \(gatewayIP) compare anche su \(otherIPs.joined(separator: ", ")). Possibile ARP spoofing."))
            }
        }

        // Stesso IP con due o più MAC diversi.
        for (ip, group) in Dictionary(grouping: observations, by: { $0.ip }) {
            let macs = Set(group.map { $0.mac.lowercased() }).sorted()
            guard macs.count >= 2 else { continue }
            alerts.append(NetworkAlert(
                id: "ipConflict-\(ip)", kind: .ipConflict, severity: .warning,
                title: "Conflitto di IP",
                detail: "L'IP \(ip) è associato a più MAC: \(macs.joined(separator: ", "))."))
        }

        // Dispositivi nuovi, escluso questo Mac.
        for device in devices where device.isNew && !device.isThisMac {
            alerts.append(NetworkAlert(
                id: "newDevice-\(device.ip)", kind: .newDevice, severity: .info,
                title: "Nuovo dispositivo sulla rete",
                detail: "IP \(device.ip), produttore \(device.vendor ?? "sconosciuto"), MAC \(device.mac ?? "sconosciuto")."))
        }

        return alerts.sorted { a, b in
            a.severity != b.severity ? a.severity > b.severity : a.id < b.id
        }
    }
}

/// MAC del gateway memorizzato per rete (chiave: indirizzo di rete della subnet).
public final class GatewayMACStore: @unchecked Sendable {
    public static let shared = GatewayMACStore()
    public func mac(forGateway ip: String, network: String) -> String? {
        UserDefaults.standard.string(forKey: "gatewayMAC.\(network).\(ip)")
    }
    public func save(mac: String, forGateway ip: String, network: String) {
        UserDefaults.standard.set(mac.lowercased(), forKey: "gatewayMAC.\(network).\(ip)")
    }
}
