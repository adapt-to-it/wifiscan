import Foundation

/// Orchestra scan + self-detect + analisi. Usata sia da CLI che da UI.
public final class ScanRunner: @unchecked Sendable {
    private let scanner: WiFiScanner
    private let analyzer: ChannelAnalyzer
    /// Reti viste di recente per BSSID: un singolo scan perde beacon deboli (tipico a 2.4 GHz),
    /// quindi teniamo quelle viste negli ultimi `retention` secondi.
    private var recent: [String: (network: ScannedNetwork, seen: Date)] = [:]
    private let recentLock = NSLock()
    public var retention: TimeInterval = 60

    public init(scanner: WiFiScanner = WiFiScanner(),
                analyzer: ChannelAnalyzer = ChannelAnalyzer()) {
        self.scanner = scanner
        self.analyzer = analyzer
    }

    public var interfaceName: String? { scanner.interfaceName() }
    public var countryCode: String? { scanner.countryCode() }

    /// Esegue uno scan completo. `connected` viene auto-rilevato; se passi override manuali
    /// (es. da flag CLI) vincono sui valori automatici.
    /// Con `cached: true` usa i risultati già in cache nel sistema (istantaneo, possono essere
    /// vecchi o vuoti); altrimenti esegue uno scan radio completo (~3-4 s).
    public func runScan(manualChannel: Int? = nil,
                        manualBssid: String? = nil,
                        manualSsid: String? = nil,
                        cached: Bool = false) throws -> ScanResult {
        let connected = ConnectedNetwork(
            channel: manualChannel ?? scanner.currentChannel(),
            bssid: manualBssid ?? scanner.currentBssid(),
            ssid: manualSsid ?? scanner.currentSsid()
        )
        let networks = accumulate(cached ? scanner.cachedScan() : try scanner.scan())
        let selfIndices = SelfDetector.identifySelf(networks: networks, connected: connected)
        let loads = analyzer.analyze(networks, excludingIndices: selfIndices)
        return ScanResult(
            timestamp: Date(),
            networks: networks,
            loads: loads,
            selfIndices: selfIndices,
            connected: connected
        )
    }
}

extension ScanRunner {
    /// Unisce lo scan corrente con le reti viste negli ultimi `retention` secondi.
    /// Senza BSSID (Location non concessa) non si può deduplicare: restituisce lo scan così com'è.
    private func accumulate(_ networks: [ScannedNetwork]) -> [ScannedNetwork] {
        let now = Date()
        recentLock.lock()
        defer { recentLock.unlock() }
        let current = Set(networks.map(\.bssid))
        for n in networks where n.bssid != "??" {
            recent[n.bssid] = (n, now)
        }
        recent = recent.filter { now.timeIntervalSince($0.value.seen) <= retention }
        return networks + recent.values.filter { !current.contains($0.network.bssid) }.map(\.network)
    }
}

// MARK: - Raccomandazioni

public struct Recommendation: Sendable {
    public let band: ScannedNetwork.Band
    public let suggestedChannel: Int
    public let suggestedWidth: Int
    public let reason: String
    public let currentChannel: Int?
    public let currentScore: Double?
    public let suggestedScore: Double
    public let improvementScore: Double?  // se siamo già ottimali → nil

    public var isAlreadyOptimal: Bool {
        guard let cur = currentChannel else { return false }
        return cur == suggestedChannel
    }
}

public enum Recommender {
    public static func recommend(for result: ScanResult) -> [Recommendation] {
        var recs: [Recommendation] = []

        // 5 GHz: preferenza per non-DFS libero
        let loads5 = result.loads.filter { $0.band == .ghz5 }
        if !loads5.isEmpty {
            let nonDFS = loads5.filter { ChannelClass.classify($0.channel).isNonDFS }
            let free = nonDFS.filter { $0.saturationScore < 0.1 }
            let best = free.min { $0.channel < $1.channel } ?? nonDFS.min { $0.saturationScore < $1.saturationScore }
            if let best = best {
                let curCh = result.connected?.channel
                let curLoad = curCh.flatMap { ch in loads5.first { $0.channel == ch } }
                let improvement = curLoad.map { max(0, $0.saturationScore - best.saturationScore) }
                let reason: String
                if best.saturationScore < 0.1 {
                    reason = "Canale libero, non-DFS (nessun rischio disconnessione radar)"
                } else {
                    reason = "Il meno congestionato tra i non-DFS"
                }
                recs.append(Recommendation(
                    band: .ghz5,
                    suggestedChannel: best.channel,
                    suggestedWidth: 80,
                    reason: reason,
                    currentChannel: curCh,
                    currentScore: curLoad?.saturationScore,
                    suggestedScore: best.saturationScore,
                    improvementScore: improvement
                ))
            }
        }

        // 2.4 GHz: solo 1/6/11
        let loads24 = result.loads.filter { $0.band == .ghz24 }
        if !loads24.isEmpty {
            let nonOverlapping = loads24.filter { [1, 6, 11].contains($0.channel) }
            if let best = nonOverlapping.min(by: { $0.saturationScore < $1.saturationScore }) {
                let curCh = result.connected?.channel
                let curLoad = curCh.flatMap { ch in loads24.first { $0.channel == ch } }
                let improvement = curLoad.map { max(0, $0.saturationScore - best.saturationScore) }
                recs.append(Recommendation(
                    band: .ghz24,
                    suggestedChannel: best.channel,
                    suggestedWidth: 20,
                    reason: "Tra i 3 canali non-overlapping (1, 6, 11)",
                    currentChannel: curCh,
                    currentScore: curLoad?.saturationScore,
                    suggestedScore: best.saturationScore,
                    improvementScore: improvement
                ))
            }
        }

        return recs
    }
}
