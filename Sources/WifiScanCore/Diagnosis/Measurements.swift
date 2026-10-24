import Foundation

// Tipi delle misure grezze della fase 0 (DIAGNOSI.md, sezione 3).
// Una sessione contiene solo misure grezze: feature e sintomi si ricalcolano dopo.
// Nessun SSID, MAC o IP pubblico: i BSSID si pseudonimizzano al salvataggio (sezione 13).

public enum ProbeTarget: String, Codable, Sendable, CaseIterable {
    case gateway, cloudflare, google

    /// Indirizzo fisso dei bersagli internet; il gateway si risolve a runtime.
    public var fixedAddress: String? {
        switch self {
        case .gateway: nil
        case .cloudflare: "1.1.1.1"
        case .google: "8.8.8.8"
        }
    }
}

/// Un ping del monitor N1. `rttMs` nil = timeout.
public struct ProbeSample: Codable, Sendable, Hashable {
    public var t: Date
    public var target: ProbeTarget
    public var rttMs: Double?
    /// Inviato durante una scansione o entro 500 ms dalla sua fine (sezione 3.2.1).
    public var contaminated: Bool
    /// Inviato durante un test sotto carico (N13).
    public var underLoad: Bool

    public init(t: Date, target: ProbeTarget, rttMs: Double?, contaminated: Bool, underLoad: Bool) {
        self.t = t; self.target = target; self.rttMs = rttMs
        self.contaminated = contaminated; self.underLoad = underLoad
    }
}

public enum DNSResolverKind: String, Codable, Sendable { case system, cloudflare }

/// Una query DNS N2 su nome casuale. `ms` nil = nessuna risposta entro il timeout.
public struct DNSSample: Codable, Sendable, Hashable {
    public var t: Date
    public var resolver: DNSResolverKind
    public var ms: Double?
    public var underLoad: Bool

    public init(t: Date, resolver: DNSResolverKind, ms: Double?, underLoad: Bool) {
        self.t = t; self.resolver = resolver; self.ms = ms; self.underLoad = underLoad
    }
}

/// Stato del collegamento Wi-Fi in un secondo (M1), più il traffico in trasmissione (N15).
public struct LinkSample: Codable, Sendable, Hashable {
    public var t: Date
    public var bssid: String?
    public var rssi: Int
    public var noise: Int
    public var txRateMbps: Double
    public var phyMode: String
    public var channel: Int?
    public var band: String?
    public var widthMHz: Int?
    /// Byte/s trasmessi sull'interfaccia Wi-Fi nell'ultimo secondo; nil al primo campione.
    public var txBytesPerSec: Double?

    public init(t: Date, bssid: String?, rssi: Int, noise: Int, txRateMbps: Double, phyMode: String,
                channel: Int?, band: String?, widthMHz: Int?, txBytesPerSec: Double?) {
        self.t = t; self.bssid = bssid; self.rssi = rssi; self.noise = noise
        self.txRateMbps = txRateMbps; self.phyMode = phyMode; self.channel = channel
        self.band = band; self.widthMHz = widthMHz; self.txBytesPerSec = txBytesPerSec
    }
}

/// Contatori e stato delle interfacce (N14, N15, N17). I contatori sono cumulativi.
public struct InterfaceSample: Codable, Sendable, Hashable {
    public var t: Date
    public var wifiTxBytes: UInt64
    public var wifiRxBytes: UInt64
    /// Interfaccia della prima route IPv4 predefinita, es. "en0" o "utun6".
    public var defaultRouteInterface: String?
    /// Un'interfaccia cablata (enX diversa dal Wi-Fi) attiva e con IPv4.
    public var ethernetActive: Bool
    public var awdlUp: Bool
    public var awdlTxBytes: UInt64

    public init(t: Date, wifiTxBytes: UInt64, wifiRxBytes: UInt64, defaultRouteInterface: String?,
                ethernetActive: Bool, awdlUp: Bool, awdlTxBytes: UInt64) {
        self.t = t; self.wifiTxBytes = wifiTxBytes; self.wifiRxBytes = wifiRxBytes
        self.defaultRouteInterface = defaultRouteInterface; self.ethernetActive = ethernetActive
        self.awdlUp = awdlUp; self.awdlTxBytes = awdlTxBytes
    }
}

public enum LinkEventKind: String, Codable, Sendable { case linkDown, linkUp, bssidChanged }

/// Evento di collegamento N16.
public struct LinkEvent: Codable, Sendable, Hashable {
    public var t: Date
    public var kind: LinkEventKind
    public var bssid: String?

    public init(t: Date, kind: LinkEventKind, bssid: String?) {
        self.t = t; self.kind = kind; self.bssid = bssid
    }
}

/// Un test sotto carico (M6 + N13). Il risultato è nil se networkQuality fallisce.
public struct LoadTestRecord: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var responsivenessRPM: Double?
    public var baseRTTms: Double?
    public var interfaceName: String?

    public init(start: Date, end: Date, downloadMbps: Double?, uploadMbps: Double?,
                responsivenessRPM: Double?, baseRTTms: Double?, interfaceName: String?) {
        self.start = start; self.end = end; self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps; self.responsivenessRPM = responsivenessRPM
        self.baseRTTms = baseRTTms; self.interfaceName = interfaceName
    }
}

public enum ActivityKind: String, Codable, Sendable { case wifiScan, lanScan }

/// Intervallo in cui l'app stessa disturba le misure.
public struct ActivityInterval: Codable, Sendable, Hashable {
    public var kind: ActivityKind
    public var start: Date
    public var end: Date

    public init(kind: ActivityKind, start: Date, end: Date) {
        self.kind = kind; self.start = start; self.end = end
    }
}

/// Rete vicina senza SSID (M2, M3).
public struct NeighborRecord: Codable, Sendable, Hashable {
    public var bssid: String
    public var channel: Int
    public var band: String
    public var widthMHz: Int
    public var rssi: Int
    public var noise: Int
    public var stationCount: Int?
    public var channelUtilization: Double?

    public init(bssid: String, channel: Int, band: String, widthMHz: Int, rssi: Int, noise: Int,
                stationCount: Int?, channelUtilization: Double?) {
        self.bssid = bssid; self.channel = channel; self.band = band; self.widthMHz = widthMHz
        self.rssi = rssi; self.noise = noise; self.stationCount = stationCount
        self.channelUtilization = channelUtilization
    }
}

public struct NeighborSnapshot: Codable, Sendable, Hashable {
    public var t: Date
    public var networks: [NeighborRecord]

    public init(t: Date, networks: [NeighborRecord]) { self.t = t; self.networks = networks }
}

public struct SessionMeta: Codable, Sendable, Hashable {
    public var id: UUID
    public var start: Date
    public var end: Date?
    public var macModel: String
    public var osVersion: String
    public var wifiInterface: String?
    public var locationAuthorized: Bool
    /// Scenari o cause note, es. "R1" o "scenario-07" (DIAGNOSI.md 12.5). Vuoto = non etichettata.
    public var labels: [String]
    public var note: String

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, macModel: String, osVersion: String,
                wifiInterface: String?, locationAuthorized: Bool, labels: [String] = [], note: String = "") {
        self.id = id; self.start = start; self.end = end; self.macModel = macModel
        self.osVersion = osVersion; self.wifiInterface = wifiInterface
        self.locationAuthorized = locationAuthorized; self.labels = labels; self.note = note
    }
}

public struct DiagnosisSession: Codable, Sendable {
    public static let currentSchema = 1

    public var schema: Int = DiagnosisSession.currentSchema
    public var meta: SessionMeta
    public var probes: [ProbeSample] = []
    public var dns: [DNSSample] = []
    public var link: [LinkSample] = []
    public var interfaces: [InterfaceSample] = []
    public var events: [LinkEvent] = []
    public var loadTests: [LoadTestRecord] = []
    public var activities: [ActivityInterval] = []
    public var neighbors: [NeighborSnapshot] = []

    public init(meta: SessionMeta) { self.meta = meta }

    /// Copia con i soli campioni da `start` in poi.
    public func trimmed(from start: Date) -> DiagnosisSession {
        guard start > .distantPast else { return self }
        var s = self
        s.probes = probes.filter { $0.t >= start }
        s.dns = dns.filter { $0.t >= start }
        s.link = link.filter { $0.t >= start }
        s.interfaces = interfaces.filter { $0.t >= start }
        s.events = events.filter { $0.t >= start }
        s.loadTests = loadTests.filter { $0.start >= start }
        s.activities = activities.filter { $0.end >= start }
        s.neighbors = neighbors.filter { $0.t >= start }
        return s
    }
}

/// Registro condiviso delle attività dell'app che disturbano le misure.
/// Chi avvia una scansione chiama `begin`, e `end` alla fine.
public final class AppActivityLog: @unchecked Sendable {
    public static let shared = AppActivityLog()

    private let lock = NSLock()
    private var open: [UUID: (ActivityKind, Date)] = [:]
    private var closed: [ActivityInterval] = []

    public func begin(_ kind: ActivityKind) -> UUID {
        let id = UUID()
        lock.lock(); open[id] = (kind, Date()); lock.unlock()
        return id
    }

    public func end(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let (kind, start) = open.removeValue(forKey: id) else { return }
        closed.append(ActivityInterval(kind: kind, start: start, end: Date()))
        if closed.count > 500 { closed.removeFirst(closed.count - 500) }
    }

    /// Intervalli chiusi più quelli ancora aperti, che terminano adesso.
    public func intervals(since: Date) -> [ActivityInterval] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return closed.filter { $0.end >= since }
            + open.values.map { ActivityInterval(kind: $0.0, start: $0.1, end: now) }
    }
}
