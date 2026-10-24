import Foundation
@testable import WifiScanCore

/// Guasti fisici simulabili. Il generatore non conosce il catalogo né i pesi (DIAGNOSI.md 12.1).
enum Fault: String, CaseIterable, Sendable {
    case weakSignal, busyChannel, slowRouter, localBufferbloat, lineBufferbloat
    case lineLoss, lineOutages, slowDNS, vpnExitNode, awdlBursts
    // Fuori catalogo, 12.2.4
    case periodicBlackout, growingLatency, oneTargetLossUnderLoad
    var outOfCatalog: Bool { [.periodicBlackout, .growingLatency, .oneTargetLossUnderLoad].contains(self) }
}

struct Scenario: Sendable {
    var faults: [Fault]
    /// Intensità per guasto tra 0 e 1: 0 = appena percepibile, 1 = grave.
    var severity: [Fault: Double]
    var session: DiagnosisSession
}

struct ScenarioGenerator {
    var seed: UInt64
    init(seed: UInt64) { self.seed = seed }

    /// Sessione di 300 s con test sotto carico tra 200 e 215 s. Le misure sono grezze, con rumore e campioni mancanti.
    mutating func make(faults: [Fault], severity: [Fault: Double], ethernet: Bool = false) -> Scenario {
        var rng = SplitMix64(state: seed)
        let session = ScenarioGenerator.build(faults: faults, severity: severity, ethernet: ethernet, rng: &rng)
        seed = rng.state
        return Scenario(faults: faults, severity: severity, session: session)
    }

    /// Scenario casuale: rete sana più 0–3 guasti compatibili, oppure un guasto fuori catalogo.
    mutating func random(outOfCatalogShare: Double = 0.1) -> Scenario {
        var rng = SplitMix64(state: seed)
        let catalog = Fault.allCases.filter { !$0.outOfCatalog }
        let extra = Fault.allCases.filter { $0.outOfCatalog }
        var faults: [Fault] = []
        if rng.chance(outOfCatalogShare) {
            faults = [extra[rng.pick(0...(extra.count - 1))]]
        } else {
            repeat {
                var pool = catalog
                pool.shuffle(using: &rng)
                faults = Array(pool.prefix(rng.pick(0...3)))
            } while faults.contains(.lineOutages) && faults.contains(.lineBufferbloat)
        }
        var severity: [Fault: Double] = [:]
        for fault in faults { severity[fault] = rng.range(0.3, 1) }
        seed = rng.state
        return make(faults: faults, severity: severity)
    }

    // MARK: - Costruzione della sessione

    private static func build(faults: [Fault], severity: [Fault: Double], ethernet: Bool,
                              rng: inout SplitMix64) -> DiagnosisSession {
        let plan = Plan(faults: Set(faults), severity: severity)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = 300
        func at(_ i: Int) -> Date { start.addingTimeInterval(Double(i)) }
        func under(_ i: Int) -> Bool { (200..<215).contains(i) }

        // Parametri fissati una volta per sessione.
        let noiseFloor = -89
        let snr = plan.has(.weakSignal) ? 20 - 12 * plan.s(.weakSignal) : rng.range(30, 45)
        let rateScale = 1 - 0.7 * plan.s(.weakSignal)
        // Un router lento ritarda anche il traffico che inoltra, non solo le risposte ai propri ping.
        let routerDelay = plan.has(.slowRouter) ? 20 + 40 * plan.s(.slowRouter) : 0
        let base: [ProbeTarget: Double] = [
            .gateway: rng.range(2, 8) + routerDelay,
            .cloudflare: rng.range(15, 40) + routerDelay,
            .google: rng.range(15, 40) + routerDelay,
        ]
        let lossBase: [ProbeTarget: Double] = [
            .gateway: rng.range(0, 0.002),
            .cloudflare: rng.range(0, 0.002),
            .google: rng.range(0, 0.002),
        ]
        let blackoutPhase = rng.pick(0...29)
        let burstPeriod = rng.pick(2...4)
        let scanStart = rng.pick(10...250)
        let bssid = "02:00:00:00:00:36"
        let route = plan.has(.vpnExitNode) ? "utun6" : (ethernet ? "en7" : "en0")

        // Blocchi di interruzione internet (lineOutages).
        var outage = [Bool](repeating: false, count: duration)
        if plan.has(.lineOutages) {
            // Si estraggono sempre 6 blocchi e si usano i primi n: così gravità diverse
            // consumano le stesse estrazioni e confrontano le stesse misure.
            let used = 2 + Int((4 * plan.s(.lineOutages)).rounded())
            for k in 0..<6 {
                let length = rng.pick(15...40)
                let from = rng.pick(0...(duration - length - 1))
                if k < used { for i in from..<(from + length) { outage[i] = true } }
            }
        }

        func blackout(_ i: Int) -> Bool {
            plan.has(.periodicBlackout) && (i - blackoutPhase + 30) % 30 < 2
        }
        func burst(_ i: Int) -> Bool { plan.has(.awdlBursts) && i % burstPeriod == 0 }
        func scanning(_ i: Int) -> Bool { (scanStart...(scanStart + 3)).contains(i) }

        // Traffico in trasmissione per secondo: 5 MB/s solo nel test sotto carico.
        var bytes = [Double](repeating: 0, count: duration)
        for i in 0..<duration { bytes[i] = under(i) ? 5e6 : rng.range(0, 2e4) }

        func probeRTT(_ target: ProbeTarget, _ i: Int) -> Double? {
            if blackout(i) { return nil }
            let load = under(i)
            var add = load ? rng.range(0, 8) : 0
            var loss = lossBase[target] ?? 0
            if plan.has(.growingLatency) {
                add += 300 * plan.s(.growingLatency) * Double(i) / 299
            }
            if target == .gateway {
                if plan.has(.weakSignal) {
                    let sw = plan.s(.weakSignal)
                    loss += 0.05 * sw
                    add += (3 + 5 * sw) * rng.gauss()
                }
                if plan.has(.busyChannel) {
                    let sb = plan.s(.busyChannel)
                    add += (2 + 4 * sb) * rng.gauss()
                    if load { add += 10 + 30 * sb }
                }
                if plan.has(.slowRouter) {
                    add += (2 + 4 * plan.s(.slowRouter)) * rng.gauss()
                }
                if plan.has(.localBufferbloat) && load {
                    add += 50 + 200 * plan.s(.localBufferbloat)
                }
                if burst(i) { add += 20 + 40 * plan.s(.awdlBursts) }
            } else {
                if plan.has(.lineBufferbloat) && load {
                    add += 80 + 320 * plan.s(.lineBufferbloat)
                }
                if plan.has(.lineLoss) && !load {
                    loss += 0.01 + 0.07 * plan.s(.lineLoss)
                }
                if plan.has(.vpnExitNode) {
                    let sv = plan.s(.vpnExitNode)
                    add += 40 + 80 * sv
                    if load { add += 50 + 150 * sv }
                    loss += 0.005 + 0.01 * sv
                }
                if target == .google && load && plan.has(.oneTargetLossUnderLoad) {
                    loss += 0.3 * plan.s(.oneTargetLossUnderLoad)
                }
                if outage[i] { return nil }
            }
            // Perdita dei guasti più lo 0,2 % di rumore. Le estrazioni avvengono sempre, così
            // con lo stesso seed gravità diverse confrontano gli stessi campioni.
            let jitter = rng.jitter()
            let lost = rng.unit() < loss
            let noise = rng.unit() < 0.002
            if lost || noise { return nil }
            return max(0.5, (base[target] ?? 0) + add) * jitter
        }

        func dnsMS(_ resolver: DNSResolverKind, _ i: Int) -> Double? {
            if blackout(i) || (resolver == .cloudflare && outage[i]) { return nil }
            if resolver == .system && plan.has(.slowDNS) {
                return (150 + 350 * plan.s(.slowDNS)) * rng.jitter()
            }
            return rng.range(10, 40)
        }

        var probes: [ProbeSample] = []
        var dns: [DNSSample] = []
        var link: [LinkSample] = []
        var interfaces: [InterfaceSample] = []
        var wifiTx: UInt64 = 1_000_000_000
        var wifiRx: UInt64 = 800_000_000
        var awdlTx: UInt64 = 4_096_000

        for i in 0..<duration {
            let contaminated = scanning(i)
            for target in ProbeTarget.allCases {
                let rtt = probeRTT(target, i).map { contaminated ? $0 + 100 : $0 }
                probes.append(ProbeSample(t: at(i), target: target, rttMs: rtt,
                                          contaminated: contaminated, underLoad: under(i)))
            }
            if i % 10 == 0 {
                for resolver in [DNSResolverKind.system, .cloudflare] {
                    dns.append(DNSSample(t: at(i), resolver: resolver, ms: dnsMS(resolver, i),
                                         underLoad: under(i)))
                }
            }
            if !ethernet {
                let snrNow = snr * rng.jitter()
                let nominal = under(i) ? rng.range(400, 600) : rng.range(104, 585)
                let rate = max(1, nominal * rateScale * rng.jitter())
                link.append(LinkSample(t: at(i), bssid: bssid, rssi: noiseFloor + Int(snrNow.rounded()),
                                       noise: noiseFloor, txRateMbps: rate, phyMode: "802.11ax (Wi-Fi 6)",
                                       channel: 36, band: "5 GHz", widthMHz: 80,
                                       txBytesPerSec: i == 0 ? nil : bytes[i]))
            }
            wifiTx &+= UInt64(bytes[i])
            wifiRx &+= UInt64(bytes[i] * 0.05)
            if plan.has(.awdlBursts) { awdlTx &+= burst(i) ? 2_000_000 : 30_000 }
            interfaces.append(InterfaceSample(t: at(i), wifiTxBytes: wifiTx, wifiRxBytes: wifiRx,
                                              defaultRouteInterface: route, ethernetActive: ethernet,
                                              awdlUp: plan.has(.awdlBursts), awdlTxBytes: awdlTx))
        }

        // Cinque istantanee delle reti vicine, ogni 60 s a partire da 30 s.
        var neighbors: [NeighborSnapshot] = []
        for k in 0..<5 {
            var nets: [NeighborRecord] = []
            let util = plan.has(.busyChannel) ? 0.5 + 0.4 * plan.s(.busyChannel) : rng.range(0.10, 0.30)
            nets.append(NeighborRecord(bssid: bssid, channel: 36, band: "5 GHz", widthMHz: 80,
                                       rssi: noiseFloor + Int(snr.rounded()), noise: noiseFloor,
                                       stationCount: rng.pick(5...20), channelUtilization: util))
            nets.append(NeighborRecord(bssid: "02:00:00:00:01:01", channel: 1, band: "2.4 GHz", widthMHz: 20,
                                       rssi: rng.pick((-85)...(-65)), noise: noiseFloor, stationCount: nil,
                                       channelUtilization: rng.range(0.1, 0.5)))
            nets.append(NeighborRecord(bssid: "02:00:00:00:01:06", channel: 6, band: "2.4 GHz", widthMHz: 20,
                                       rssi: rng.pick((-85)...(-65)), noise: noiseFloor, stationCount: nil,
                                       channelUtilization: rng.range(0.1, 0.5)))
            nets.append(NeighborRecord(bssid: "02:00:00:00:01:95", channel: 149, band: "5 GHz", widthMHz: 80,
                                       rssi: rng.pick((-85)...(-65)), noise: noiseFloor, stationCount: nil,
                                       channelUtilization: rng.range(0.1, 0.5)))
            if plan.has(.busyChannel) {
                for n in 0..<(4 + Int((4 * plan.s(.busyChannel)).rounded())) {
                    nets.append(NeighborRecord(bssid: "02:00:00:00:02:0\(n)", channel: 36, band: "5 GHz",
                                               widthMHz: 80, rssi: rng.pick((-75)...(-60)), noise: noiseFloor,
                                               stationCount: nil, channelUtilization: nil))
                }
            }
            neighbors.append(NeighborSnapshot(t: at(30 + 60 * k), networks: nets))
        }

        // RPM come networkQuality: giri di andata e ritorno al minuto con la linea satura.
        let loaded = probes.filter { $0.target == .cloudflare && $0.underLoad }.compactMap(\.rttMs)
        let rpm: Double? = loaded.isEmpty ? nil : 60_000 / (loaded.reduce(0, +) / Double(loaded.count))
        let loadTest = LoadTestRecord(start: at(200), end: at(215),
                                      downloadMbps: rng.range(200, 400),
                                      uploadMbps: 40 * rng.jitter(),
                                      responsivenessRPM: rpm,
                                      baseRTTms: base[.cloudflare],
                                      interfaceName: route)
        let activity = ActivityInterval(kind: .wifiScan, start: at(scanStart), end: at(scanStart + 3))

        // Identificativo della sessione derivato dal seed, così le misure restano uguali a parità di seed.
        var raw: [UInt8] = []
        for _ in 0..<16 { raw.append(UInt8(truncatingIfNeeded: rng.next())) }
        let id = UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                             raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
        let meta = SessionMeta(id: id, start: start, end: at(duration), macModel: "MacBookPro18,1",
                               osVersion: "15.7.9", wifiInterface: "en0", locationAuthorized: true)

        var session = DiagnosisSession(meta: meta)
        session.probes = probes
        session.dns = dns
        session.link = link
        session.interfaces = interfaces
        session.loadTests = [loadTest]
        session.activities = [activity]
        session.neighbors = neighbors
        return session
    }
}

/// Guasti presenti e intensità, letti dal generatore.
private struct Plan {
    let faults: Set<Fault>
    let severity: [Fault: Double]

    func has(_ fault: Fault) -> Bool { faults.contains(fault) }

    /// Intensità in [0, 1] del guasto presente; 0 se assente.
    func s(_ fault: Fault) -> Double {
        faults.contains(fault) ? min(1, max(0, severity[fault] ?? 1)) : 0
    }
}

/// PRNG SplitMix64. Lo stato è il seed: stesso seed, stesse sequenze.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniforme in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }

    mutating func pick(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }

    mutating func chance(_ p: Double) -> Bool { unit() < p }

    /// Normale standard con Box-Muller, troncata a ±2 deviazioni standard.
    mutating func gauss() -> Double {
        let u1 = max(unit(), 1e-12)
        let g = (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * unit())
        return min(2, max(-2, g))
    }

    /// Fattore moltiplicativo gaussiano: ±10 % entro 2 deviazioni standard.
    mutating func jitter() -> Double { 1 + 0.05 * gauss() }
}
