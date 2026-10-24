import Foundation
@testable import WifiScanCore

// Scenari di guasto scritti senza guardare il modello causale (DIAGNOSI.md, 12.1).
// Ogni scenario descrive la rete secondo per secondo. Nessun Date() né random di sistema:
// il rumore viene da un PRNG locale con seme fisso, quindi ogni esecuzione produce gli stessi dati.

enum AdversarialScenarios {
    static let seconds = 300
    static let loadRange = 200..<215
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    static func all() -> [(name: String, session: DiagnosisSession)] {
        scenarios().enumerated().map { (name: $0.element.name, session: build($0.element, index: $0.offset)) }
    }

    /// Rete domestica sana: gateway 3 ms, internet 18-19 ms, DNS 12-14 ms, Wi-Fi 5 GHz canale 36 a -52 dBm.
    private static func healthy(_ i: Int) -> Tick {
        var k = Tick()
        k.wifiTxBps = loadRange.contains(i) ? 900_000 : 40_000
        return k
    }

    private static func scenarios() -> [AdversarialCase] {
        [
            // MTU da 1280 su un tunnel: i ping piccoli passano, i pacchetti da 1500 byte vengono scartati senza ICMP.
            AdversarialCase(name: "mtu-pacchetti-grandi", seed: 1, loadResult: (nil, nil, nil)) { i, _ in
                healthy(i)
            },

            // AAAA annunciato ma senza risposta: il resolver di sistema attende il timeout IPv6 e poi risponde via IPv4.
            AdversarialCase(name: "ipv6-rotto", seed: 2) { i, _ in
                var k = healthy(i)
                k.dnsSys = 900
                return k
            },

            // Portale captive non accettato: il DNS del portale risponde a tutto, internet non raggiungibile fino a 120 s.
            AdversarialCase(name: "captive-portal", seed: 3) { i, _ in
                var k = healthy(i)
                if i < 120 {
                    k.cf = nil; k.goo = nil; k.dnsCf = nil; k.dnsSys = 20
                }
                return k
            },

            // Router che riavvia: l'AP scompare per 40 s, poi torna con un altro BSSID e un altro canale.
            AdversarialCase(name: "router-riavvio-meta-sessione", seed: 4) { i, _ in
                var k = healthy(i)
                if (100..<140).contains(i) {
                    k.gw = nil; k.cf = nil; k.goo = nil; k.dnsSys = nil; k.dnsCf = nil
                    k.bssid = nil; k.channel = nil; k.band = nil; k.width = nil
                    k.rssi = -100; k.txRate = 0; k.phy = ""; k.wifiTxBps = 0; k.route = nil
                } else if i >= 140 {
                    k.bssid = apB; k.channel = 149
                }
                return k
            },

            // Mesh con steering aggressivo: il Mac salta tra due AP ogni 20 s, con perdita di 2 s a ogni passaggio.
            AdversarialCase(name: "bssid-ogni-20-secondi", seed: 5) { i, _ in
                var k = healthy(i)
                let onB = (i / 20) % 2 == 1
                k.bssid = onB ? apB : apA
                k.channel = onB ? 149 : 36
                k.rssi = onB ? -76 : -48
                if i % 20 < 2 {
                    k.gw = nil; k.cf = nil; k.goo = nil
                }
                return k
            },

            // Il server DHCP rinnova il lease con un altro gateway: il vecchio IP non risponde più, internet e DNS sono sani.
            AdversarialCase(name: "dhcp-cambia-gateway", seed: 6) { i, _ in
                var k = healthy(i)
                if i >= 150 { k.gw = nil }
                return k
            },

            // Firewall che scarta l'ICMP verso 8.8.8.8 ma non verso 1.1.1.1 né verso il gateway.
            AdversarialCase(name: "icmp-filtrato-8888", seed: 7) { i, _ in
                var k = healthy(i)
                k.goo = nil
                return k
            },

            // Il client VPN riprende la route di default ogni 7 s: quando passa su utun, i bersagli internet aggiungono 45 ms.
            AdversarialCase(name: "route-en0-utun-oscilla", seed: 8) { i, _ in
                var k = healthy(i)
                if (i / 7) % 2 == 1 {
                    k.route = "utun6"
                    k.cf = k.cf.map { $0 + 45 }
                    k.goo = k.goo.map { $0 + 45 }
                }
                return k
            },

            // Client 802.11g nella cella: la protezione o il basic rate tengono il rate a 6 Mbit/s con segnale ottimo.
            AdversarialCase(name: "rssi-ottimo-rate-6-mbit", seed: 9) { i, _ in
                var k = healthy(i)
                k.phy = "802.11g"; k.band = "2.4"; k.channel = 6; k.width = 20
                k.rssi = -50; k.noise = -92; k.txRate = 6
                return k
            },

            // Risparmio energetico o buffer dell'AP: la latenza alterna 5 ms e 300 ms ogni 2 s, senza perdite.
            AdversarialCase(name: "latenza-bimodale-5-300", seed: 10) { i, _ in
                var k = healthy(i)
                let slow = (i / 2) % 2 == 1
                k.gw = slow ? 300 : 5
                k.cf = slow ? 305 : 19
                k.goo = slow ? 306 : 20
                return k
            },

            // Mac in sospensione per 60 s: nessun campione su nessuna serie, come un buco nei dati.
            AdversarialCase(name: "sospensione-60-secondi", seed: 11) { i, _ in
                var k = healthy(i)
                if (120..<180).contains(i) {
                    k.probesOn = false; k.linkOn = false
                }
                return k
            },

            // NTP riporta l'orologio avanti di un'ora a 150 s: i campioni successivi hanno timestamp spostati.
            AdversarialCase(name: "orologio-salta-avanti", seed: 12) { i, _ in
                var k = healthy(i)
                if i >= 150 { k.skew = 3600 }
                return k
            },

            // Cache del framework che non si aggiorna: ogni valore è costante, RTT esatto, nessun jitter.
            AdversarialCase(name: "misure-identiche", seed: 13) { i, _ in
                var k = Tick()
                k.jitter = false
                return k
            },

            // Mac collegato via cavo con il Wi-Fi spento: il monitor legge un collegamento nullo e la route è su en1.
            AdversarialCase(name: "cavo-wifi-spento", seed: 14, loadInterface: "en1") { i, _ in
                var k = healthy(i)
                k.bssid = nil; k.channel = nil; k.band = nil; k.width = nil
                k.rssi = -100; k.txRate = 0; k.phy = ""; k.wifiTxBps = 0
                k.route = "en1"; k.ethernet = true
                return k
            },

            // Il resolver del router filtra o perde le query: il DNS di sistema non risponde mai, 1.1.1.1 sì.
            AdversarialCase(name: "dns-di-sistema-muto", seed: 15) { i, _ in
                var k = healthy(i)
                k.dnsSys = nil
                return k
            },

            // Radar sul canale 100: l'AP sposta il canale a 52 mantenendo il BSSID, con 3 s di silenzio al cambio.
            AdversarialCase(name: "dfs-cambio-canale", seed: 16) { i, _ in
                var k = healthy(i)
                k.channel = i < 120 ? 100 : 52
                if (120..<123).contains(i) {
                    k.gw = nil; k.cf = nil; k.goo = nil; k.dnsSys = nil; k.dnsCf = nil
                }
                return k
            },
        ]
    }

    private static func build(_ s: AdversarialCase, index: Int) -> DiagnosisSession {
        var rng = Rng(seed: s.seed)
        var session = DiagnosisSession(meta: SessionMeta(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index + 1))),
            start: origin, end: origin.addingTimeInterval(Double(seconds - 1)),
            macModel: "MacBookPro18,1", osVersion: "15.7.9", wifiInterface: "en0",
            locationAuthorized: true, note: s.name))

        var wifiTx: UInt64 = 0
        var wifiRx: UInt64 = 0
        var awdlTx: UInt64 = 0
        var lastBSSID: String? = nil

        for i in 0..<seconds {
            let tick = s.tick(i, &rng)
            let t = origin.addingTimeInterval(Double(i) + tick.skew)
            let loaded = loadRange.contains(i)

            if tick.probesOn {
                let targets: [(ProbeTarget, Double?)] = [(.gateway, tick.gw), (.cloudflare, tick.cf), (.google, tick.goo)]
                for (target, rtt) in targets {
                    session.probes.append(ProbeSample(t: t, target: target,
                                                      rttMs: noisy(rtt, tick.jitter, &rng),
                                                      contaminated: false, underLoad: loaded))
                }
                if i % 10 == 0 {
                    session.dns.append(DNSSample(t: t, resolver: .system,
                                                 ms: noisy(tick.dnsSys, tick.jitter, &rng), underLoad: loaded))
                    session.dns.append(DNSSample(t: t, resolver: .cloudflare,
                                                 ms: noisy(tick.dnsCf, tick.jitter, &rng), underLoad: loaded))
                }
            }

            if tick.linkOn {
                session.link.append(LinkSample(t: t, bssid: tick.bssid, rssi: tick.rssi, noise: tick.noise,
                                               txRateMbps: tick.txRate, phyMode: tick.phy, channel: tick.channel,
                                               band: tick.band, widthMHz: tick.width,
                                               txBytesPerSec: i == 0 ? nil : tick.wifiTxBps))
                wifiTx &+= UInt64(tick.wifiTxBps)
                wifiRx &+= 30_000
                if tick.awdl { awdlTx &+= 4_000 }
                session.interfaces.append(InterfaceSample(t: t, wifiTxBytes: wifiTx, wifiRxBytes: wifiRx,
                                                          defaultRouteInterface: tick.route,
                                                          ethernetActive: tick.ethernet, awdlUp: tick.awdl,
                                                          awdlTxBytes: awdlTx))
                if let kind = linkEvent(from: lastBSSID, to: tick.bssid) {
                    session.events.append(LinkEvent(t: t, kind: kind, bssid: tick.bssid))
                }
                lastBSSID = tick.bssid
            }

            if i % 60 == 0 {
                session.neighbors.append(NeighborSnapshot(t: t, networks: neighborhood))
            }
        }

        session.loadTests.append(LoadTestRecord(start: origin.addingTimeInterval(Double(loadRange.lowerBound)),
                                                end: origin.addingTimeInterval(Double(loadRange.upperBound)),
                                                downloadMbps: s.loadResult.down, uploadMbps: s.loadResult.up,
                                                responsivenessRPM: s.loadResult.rpm, baseRTTms: 4,
                                                interfaceName: s.loadInterface))
        return session
    }

    /// Eventi derivati dal cambio di BSSID tra due campioni di link.
    private static func linkEvent(from old: String?, to new: String?) -> LinkEventKind? {
        switch (old, new) {
        case (nil, nil): return nil
        case (nil, _): return .linkUp
        case (_, nil): return .linkDown
        case let (a?, b?): return a == b ? nil : .bssidChanged
        }
    }

    private static func noisy(_ v: Double?, _ jitter: Bool, _ rng: inout Rng) -> Double? {
        guard let v = v else { return nil }
        return jitter ? v + rng.unit() * 1.5 : v
    }
}

private let apA = "02:00:00:00:00:01"
private let apB = "02:00:00:00:00:02"

private let neighborhood: [NeighborRecord] = [
    NeighborRecord(bssid: "02:00:00:10:00:01", channel: 1, band: "2.4", widthMHz: 20, rssi: -71, noise: -92,
                   stationCount: 9, channelUtilization: 0.35),
    NeighborRecord(bssid: "02:00:00:10:00:02", channel: 11, band: "2.4", widthMHz: 20, rssi: -78, noise: -92,
                   stationCount: 5, channelUtilization: 0.25),
    NeighborRecord(bssid: "02:00:00:10:00:03", channel: 149, band: "5", widthMHz: 80, rssi: -79, noise: -93,
                   stationCount: 4, channelUtilization: 0.20),
]

/// Stato della rete in un secondo. Un campo di misura nil = timeout. `probesOn` o `linkOn` false = nessun campione.
private struct Tick {
    var gw: Double? = 3
    var cf: Double? = 18
    var goo: Double? = 19
    var dnsSys: Double? = 12
    var dnsCf: Double? = 14
    var probesOn = true
    var linkOn = true
    var jitter = true
    /// Spostamento dell'orologio di sistema rispetto al tempo reale.
    var skew: TimeInterval = 0
    var bssid: String? = apA
    var channel: Int? = 36
    var band: String? = "5"
    var width: Int? = 80
    var rssi = -52
    var noise = -90
    var txRate = 866.0
    var phy = "802.11ax"
    var wifiTxBps = 40_000.0
    var route: String? = "en0"
    var ethernet = false
    var awdl = false
}

private struct AdversarialCase {
    var name: String
    var seed: UInt64
    var loadResult: (down: Double?, up: Double?, rpm: Double?) = (380, 35, 850)
    var loadInterface = "en0"
    var tick: (Int, inout Rng) -> Tick
}

/// SplitMix64: PRNG deterministico, senza dipendenze dal sistema.
private struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Valore uniforme in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / 9_007_199_254_740_992.0
    }
}
