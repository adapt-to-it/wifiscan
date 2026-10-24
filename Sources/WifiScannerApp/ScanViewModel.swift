import Foundation
import Observation
import WifiScanCore

@MainActor
@Observable
final class ScanViewModel {
    enum State: Sendable {
        case idle
        case scanning
        case done(ScanResult)
        case failed(String)
    }

    var state: State = .idle
    var lastResult: ScanResult?
    var lastError: String?

    // Overrides manuali (per debug o setup utenti)
    var overrideSsid: String = ""
    var overrideChannel: String = ""

    private let runner = ScanRunner()
    private var currentTask: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    /// Cancella eventuali scan in corso. Da chiamare quando la finestra/scena si chiude.
    func cancelScan() {
        currentTask?.cancel()
        currentTask = nil
    }

    var interfaceLabel: String {
        let iface = runner.interfaceName ?? "??"
        let country = runner.countryCode ?? "??"
        return "\(iface) · \(country)"
    }

    func scan() async {
        // Cancella eventuale scan precedente
        currentTask?.cancel()
        state = .scanning
        // Capturo gli input ora che siamo già su MainActor
        let ch = Int(overrideChannel.trimmingCharacters(in: .whitespaces))
        let ssidTrim = overrideSsid.trimmingCharacters(in: .whitespaces)
        let ssid: String? = ssidTrim.isEmpty ? nil : ssidTrim
        let runner = self.runner

        // Mostra subito la cache di sistema, se c'è, mentre lo scan radio è in corso.
        if let cachedResult = try? runner.runScan(manualChannel: ch, manualSsid: ssid, cached: true),
           !cachedResult.networks.isEmpty {
            lastResult = cachedResult
        }

        let task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try runner.runScan(manualChannel: ch, manualSsid: ssid)
                }.value
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.lastResult = result
                    self?.lastError = nil
                    self?.state = .done(result)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
        currentTask = task
        await task.value
    }

    var recommendations: [Recommendation] {
        guard let lastResult else { return [] }
        return Recommender.recommend(for: lastResult)
    }

    func loads(for band: ScannedNetwork.Band) -> [ChannelLoad] {
        lastResult?.loads.filter { $0.band == band } ?? []
    }

    func connectedNetworkSummary() -> (ssid: String?, channel: Int?, rssi: Int?, band: ScannedNetwork.Band?) {
        guard let r = lastResult else { return (nil, nil, nil, nil) }
        let ch = r.connected?.channel
        let strongestSelf = r.selfIndices.compactMap { r.networks[safe: $0] }.max(by: { $0.rssi < $1.rssi })
        return (
            r.connected?.ssid ?? strongestSelf?.ssid,
            ch,
            strongestSelf?.rssi,
            strongestSelf?.band
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
