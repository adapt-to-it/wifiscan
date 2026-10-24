import Foundation
import Observation
import WifiScanCore

@MainActor
@Observable
final class DiagnosticsViewModel {
    // Connettività (verifica hop comuni)
    var gatewayIP: String?
    var gatewayPing: PingStats?
    var publicPing1111: PingStats?
    var publicPing8888: PingStats?
    var checkingConnectivity = false

    // Info internet pubblico
    var publicInfo: PublicInternetInfo?
    var loadingPublicInfo = false

    // Qualità della rete (networkQuality)
    var networkQuality: NetworkQualityResult?
    var networkQualityRunning = false
    var networkQualityError: String?

    // Timeline ping al gateway (ultimi 60 sample, 1 al secondo)
    var pingTimeline: [PingSample] = []
    var liveMonitoringTask: Task<Void, Never>?
    var liveMonitoringActive: Bool { liveMonitoringTask != nil }

    private let pinger = Pinger()

    // MARK: - Connettività

    func runConnectivityCheck() async {
        guard !checkingConnectivity else { return }
        checkingConnectivity = true
        defer { checkingConnectivity = false }

        // Gateway
        let gw = await DiagnosticsService.defaultGateway()
        gatewayIP = gw
        if let gw = gw {
            let samples = await pinger.ping(host: gw, count: 3, timeout: 1.0)
            gatewayPing = PingStats(samples: samples)
        } else {
            gatewayPing = nil
        }

        // Public hosts
        async let p1 = pinger.ping(host: "1.1.1.1", count: 3, timeout: 1.5)
        async let p2 = pinger.ping(host: "8.8.8.8", count: 3, timeout: 1.5)
        let (s1, s2) = await (p1, p2)
        publicPing1111 = PingStats(samples: s1)
        publicPing8888 = PingStats(samples: s2)
    }

    // MARK: - Info pubblico

    func loadPublicInfo() async {
        loadingPublicInfo = true
        defer { loadingPublicInfo = false }
        publicInfo = await DiagnosticsService.fetchPublicInfo()
    }

    // MARK: - Qualità della rete

    func runNetworkQuality() async {
        guard !networkQualityRunning else { return }
        networkQualityRunning = true
        networkQualityError = nil
        defer { networkQualityRunning = false }
        do {
            networkQuality = try await NetworkQualityRunner.run()
        } catch {
            networkQuality = nil
            networkQualityError = error.localizedDescription
        }
    }

    // MARK: - Live monitoring

    func startLiveMonitoring() {
        guard liveMonitoringTask == nil else { return }
        pingTimeline.removeAll()
        let pinger = self.pinger
        let initialGW = self.gatewayIP
        let task = Task { [weak self] in
            // Risolvi il gateway una volta sola se non già noto.
            var host: String? = initialGW
            if host == nil {
                host = await DiagnosticsService.defaultGateway()
            }
            guard let host else { return }
            while !Task.isCancelled {
                let s = await pinger.singlePing(host: host, timeout: 1.0)
                await MainActor.run {
                    guard let self else { return }
                    var t = self.pingTimeline
                    t.append(s)
                    if t.count > 60 { t.removeFirst(t.count - 60) }
                    self.pingTimeline = t
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        liveMonitoringTask = task
    }

    func stopLiveMonitoring() {
        liveMonitoringTask?.cancel()
        liveMonitoringTask = nil
    }

    /// Cancella tutto (cleanup on terminate).
    func cancelAll() {
        stopLiveMonitoring()
    }
}
