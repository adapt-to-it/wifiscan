import SwiftUI
import Charts
import WifiScanCore

struct RoamingEvent: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let fromBSSID: String?
    let toBSSID: String?
}

@MainActor
@Observable
final class LinkViewModel {
    var current: LinkSnapshot?
    var history: [LinkSnapshot] = []        // ultimi 300 campioni (5 min a 1 Hz)
    var roamingEvents: [RoamingEvent] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sample() {
        let snap = LinkMonitor.snapshot()
        current = snap
        guard let snap else { return }
        if let prev = history.last, prev.bssid != snap.bssid {
            roamingEvents.append(RoamingEvent(date: snap.timestamp,
                                              fromBSSID: prev.bssid,
                                              toBSSID: snap.bssid))
        }
        history.append(snap)
        if history.count > 300 {
            history.removeFirst(history.count - 300)
        }
    }
}

struct LinkView: View {
    let vm: LinkViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = vm.current {
                    statusCard(s)
                } else {
                    Text("Nessuna connessione Wi-Fi")
                        .foregroundStyle(.secondary)
                        .linkCardStyle()
                }
                if !vm.history.isEmpty {
                    chartCard
                }
                if !vm.roamingEvents.isEmpty {
                    roamingCard
                }
            }
            .padding()
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private func statusCard(_ s: LinkSnapshot) -> some View {
        let quality = LinkMonitor.quality(snr: s.snr)
        return VStack(alignment: .leading, spacing: 12) {
            Text(s.ssid ?? "SSID non disponibile")
                .font(.title2.bold())
            Text(s.bssid ?? "BSSID non disponibile")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("RSSI", "\(s.rssi) dBm")
                row("Rumore", "\(s.noise) dBm")
                row("SNR", "\(s.snr) dB (\(quality.rawValue))")
                row("Velocità TX", "\(s.txRateMbps.formatted()) Mbps")
                row("PHY", s.phyMode)
                row("Canale", channelText(s))
                row("Sicurezza", s.security)
                row("Potenza", "\(s.txPowerMilliwatt) mW")
            }
        }
        .linkCardStyle()
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segnale").font(.headline)
            Chart {
                ForEach(vm.history, id: \.timestamp) { s in
                    LineMark(x: .value("Ora", s.timestamp), y: .value("dBm", s.rssi))
                        .foregroundStyle(by: .value("Metrica", "RSSI"))
                    LineMark(x: .value("Ora", s.timestamp), y: .value("dBm", s.noise))
                        .foregroundStyle(by: .value("Metrica", "Rumore"))
                }
            }
            .chartYScale(domain: -100 ... -20)
            .frame(height: 200)
        }
        .linkCardStyle()
    }

    private var roamingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Roaming").font(.headline)
            ForEach(vm.roamingEvents.reversed()) { e in
                Text("\(e.date.formatted(date: .omitted, time: .standard))  \(e.fromBSSID ?? "—") → \(e.toBSSID ?? "—")")
                    .font(.callout.monospaced())
            }
        }
        .linkCardStyle()
    }

    private func channelText(_ s: LinkSnapshot) -> String {
        guard let ch = s.channel else { return "—" }
        var parts = ["\(ch)"]
        if let band = s.band { parts.append(linkBandLabel(band)) }
        if let width = s.widthMHz { parts.append("\(width) MHz") }
        return parts.joined(separator: " · ")
    }

    private func linkBandLabel(_ band: ScannedNetwork.Band) -> String {
        switch band {
        case .ghz24: return "2,4 GHz"
        case .ghz5: return "5 GHz"
        case .ghz6: return "6 GHz"
        }
    }
}

private extension View {
    /// Stile @stile-card: padding 20, sfondo arrotondato.
    func linkCardStyle() -> some View {
        self.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
    }
}
