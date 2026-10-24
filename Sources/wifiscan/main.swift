import Foundation
import WifiScanCore

// MARK: - Rendering (CLI only)

enum Color {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let cyan = "\u{001B}[36m"
}

func pad(_ s: String, _ width: Int) -> String {
    let visible = s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m",
                                          with: "", options: .regularExpression)
    if visible.count >= width { return s }
    return s + String(repeating: " ", count: width - visible.count)
}

func bar(value: Double, max: Double, width: Int = 20) -> String {
    let normalized = max > 0 ? value / max : 0
    let filled = Swift.min(width, Int(normalized * Double(width)))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func colorForScore(_ score: Double, max: Double) -> String {
    if max == 0 { return Color.green }
    let ratio = score / max
    if ratio < 0.25 { return Color.green }
    if ratio < 0.6  { return Color.yellow }
    return Color.red
}

func printReport(_ result: ScanResult) {
    print("\n\(Color.bold)Reti rilevate: \(result.networks.count)\(Color.reset)")
    if !result.selfIndices.isEmpty {
        print("\(Color.dim)Rete propria identificata: \(result.selfIndices.count) BSSID (esclusi dallo scoring)\(Color.reset)")
    }

    print("\n\(Color.bold)Reti vicine:\(Color.reset)")
    let indexed = result.networks.enumerated().sorted { $0.element.rssi > $1.element.rssi }
    print("  " + pad("SSID", 32) + pad("Banda", 9) + pad("Ch", 5) + pad("Largh.", 9) + pad("RSSI", 10) + "Note")
    for (i, n) in indexed {
        let ssidShort = String(n.ssid.prefix(30))
        let isSelf = result.selfIndices.contains(i)
        let isWeak = n.rssi < Scoring.rssiFloor
        var notes: [String] = []
        if isSelf { notes.append("\(Color.cyan)● TU\(Color.reset)") }
        if isWeak { notes.append("\(Color.dim)debole\(Color.reset)") }
        print("  "
              + pad(ssidShort, 32)
              + pad(n.band.rawValue, 9)
              + pad(String(n.channel), 5)
              + pad("\(n.width) MHz", 9)
              + pad("\(n.rssi) dBm", 10)
              + notes.joined(separator: " "))
    }

    for band in [ScannedNetwork.Band.ghz24, .ghz5] {
        let bandLoads = result.loads.filter { $0.band == band }
        guard !bandLoads.isEmpty else { continue }
        let maxScore = bandLoads.map(\.saturationScore).max() ?? 1.0

        print("\n\(Color.bold)Saturazione canali \(band.rawValue):\(Color.reset)")
        print("  " + pad("Ch", 5) + pad("Pri", 5) + pad("Ovl", 5) + pad("Adj", 5)
              + pad("Saturazione", 23) + pad("Score", 7) + "Tipo")

        for load in bandLoads.sorted(by: { $0.saturationScore > $1.saturationScore }) {
            let color = colorForScore(load.saturationScore, max: maxScore)
            let barStr = bar(value: load.saturationScore, max: maxScore)
            let scoreStr = String(format: "%.2f", load.saturationScore)
            let cls = band == .ghz5 ? ChannelClass.classify(load.channel).label : ""
            let typeLabel = cls.isEmpty ? "" : " (\(cls))"
            let isMine = result.connected?.channel == load.channel
            let prefix = isMine ? "\(Color.cyan)●\(Color.reset) " : "  "
            print(prefix
                  + pad(String(load.channel), 5)
                  + pad(String(load.primaryNetworks.count), 5)
                  + pad(String(load.overlapNetworks.count), 5)
                  + pad(String(load.adjacentNetworks.count), 5)
                  + color + pad(barStr, 23) + Color.reset
                  + pad(scoreStr, 7)
                  + typeLabel)
        }
    }
}

func printExplain(_ result: ScanResult) {
    let recs = Recommender.recommend(for: result)
    print("\n\(Color.bold)\(Color.cyan)═══ Raccomandazioni operative ═══\(Color.reset)")
    for rec in recs {
        print("\n\(Color.bold)\(rec.band.rawValue):\(Color.reset)")
        print("  \(Color.green)► Canale consigliato: \(rec.suggestedChannel) @ \(rec.suggestedWidth) MHz\(Color.reset)")
        print("    \(Color.dim)\(rec.reason)\(Color.reset)")
        if let cur = rec.currentChannel {
            if rec.isAlreadyOptimal {
                print("    \(Color.green)✓ Sei già sul canale ottimale\(Color.reset)")
            } else if let imp = rec.improvementScore, imp > 0.2 {
                print("    \(Color.yellow)→ Migrare dal canale \(cur) al \(rec.suggestedChannel) ridurrebbe la saturazione di \(String(format: "%.2f", imp))\(Color.reset)")
            }
        }
    }
    print("\n\(Color.dim)Nota: scoring esclude reti < -85 dBm e deduplica APs con stessi primi 5 byte del BSSID.\(Color.reset)")
}

// MARK: - Main

setbuf(stdout, nil)

let args = CommandLine.arguments
let continuous = args.contains("--continuous") || args.contains("-c")
let explain = args.contains("--explain") || args.contains("-e")
let interval: TimeInterval = 10

var manualBssid: String? = nil
var manualSsid: String? = nil
var manualChannel: Int? = nil
for (i, a) in args.enumerated() {
    if a == "--my-bssid",   i + 1 < args.count { manualBssid = args[i + 1].lowercased() }
    if a == "--my-ssid",    i + 1 < args.count { manualSsid = args[i + 1] }
    if a == "--my-channel", i + 1 < args.count { manualChannel = Int(args[i + 1]) }
}

if args.contains("--help") || args.contains("-h") {
    print("""
    wifiscan — analisi saturazione canali Wi-Fi

    Uso:
      wifiscan [opzioni]

    Opzioni:
      -c, --continuous       Scan ripetuto ogni 10s
      -e, --explain          Mostra raccomandazioni operative
      --my-ssid <SSID>       Identifica la tua rete per SSID
      --my-bssid <BSSID>     Identifica per BSSID esatto
      --my-channel <N>       Identifica come rete più forte sul canale
      -h, --help             Questo messaggio
    """)
    exit(0)
}

let runner = ScanRunner()
if let iface = runner.interfaceName {
    print("\(Color.dim)Interfaccia: \(iface) | Country: \(runner.countryCode ?? "??")\(Color.reset)")
}

repeat {
    print("\n\(Color.cyan)→ Scansione in corso...\(Color.reset)")
    do {
        let result = try runner.runScan(
            manualChannel: manualChannel,
            manualBssid: manualBssid,
            manualSsid: manualSsid
        )
        printReport(result)
        if explain { printExplain(result) }
    } catch {
        print("\(Color.red)Errore: \(error.localizedDescription)\(Color.reset)")
    }
    if continuous {
        print("\n\(Color.dim)Prossima scansione tra \(Int(interval))s (Ctrl+C per uscire)\(Color.reset)")
        Thread.sleep(forTimeInterval: interval)
    }
} while continuous
