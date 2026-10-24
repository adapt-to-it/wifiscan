import SwiftUI
import WifiScanCore

struct OverviewView: View {
    let vm: ScanViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConnectedNetworkCard(vm: vm)
                BandSummaryRow(vm: vm)
                RecommendationPreview(vm: vm)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Card rete connessa

struct ConnectedNetworkCard: View {
    let vm: ScanViewModel

    var body: some View {
        let summary = vm.connectedNetworkSummary()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rete connessa")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let band = summary.band {
                    Text(band.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "wifi")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.ssid ?? "Non identificata")
                        .font(.title2.bold())
                    HStack(spacing: 12) {
                        if let ch = summary.channel {
                            Label("Canale \(ch)", systemImage: "antenna.radiowaves.left.and.right")
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                        }
                        if let rssi = summary.rssi {
                            Label("\(rssi) dBm", systemImage: "dot.radiowaves.right")
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                                .foregroundStyle(qualityColor(rssi: rssi))
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if let rssi = summary.rssi {
                    QualityBars(rssi: rssi)
                }
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private func qualityColor(rssi: Int) -> Color {
        if rssi >= -55 { return .green }
        if rssi >= -70 { return .yellow }
        return .red
    }
}

struct QualityBars: View {
    let rssi: Int
    var body: some View {
        let level = qualityLevel
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i <= level ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: CGFloat(8 + i * 5))
            }
        }
    }
    private var qualityLevel: Int {
        if rssi >= -50 { return 4 }
        if rssi >= -60 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }
}

// MARK: - Riepilogo bande

struct BandSummaryRow: View {
    let vm: ScanViewModel
    var body: some View {
        HStack(spacing: 16) {
            BandSummaryCard(vm: vm, band: .ghz24)
            BandSummaryCard(vm: vm, band: .ghz5)
        }
    }
}

struct BandSummaryCard: View {
    let vm: ScanViewModel
    let band: ScannedNetwork.Band

    var body: some View {
        let loads = vm.loads(for: band)
        let avg = loads.isEmpty ? 0 : loads.map(\.saturationScore).reduce(0, +) / Double(loads.count)
        let best = loads.min { $0.saturationScore < $1.saturationScore }
        let active = loads.reduce(0) { $0 + ($1.totalInterferers > 0 ? 1 : 0) }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: band == .ghz24 ? "antenna.radiowaves.left.and.right" : "wifi")
                    .foregroundStyle(.tint)
                Text(band.rawValue)
                    .font(.headline)
                Spacer()
                Text("\(active) canali con interferenze")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Saturazione media")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", avg))
                        .font(.title2.monospacedDigit().weight(.semibold))
                }
                Spacer()
                if let best = best {
                    VStack(alignment: .trailing) {
                        Text("Migliore")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Canale \(best.channel)")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        }
    }
}

// MARK: - Preview raccomandazioni

struct RecommendationPreview: View {
    let vm: ScanViewModel

    var body: some View {
        let recs = vm.recommendations
        VStack(alignment: .leading, spacing: 10) {
            Text("Raccomandazioni")
                .font(.headline)
            if recs.isEmpty {
                Text("Esegui uno scan per vedere i suggerimenti.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recs, id: \.suggestedChannel) { rec in
                    RecommendationRow(rec: rec)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        }
    }
}

struct RecommendationRow: View {
    let rec: Recommendation
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rec.isAlreadyOptimal ? "checkmark.seal.fill" : "arrow.right.circle.fill")
                .foregroundStyle(rec.isAlreadyOptimal ? Color.green : Color.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rec.band.rawValue) → canale \(rec.suggestedChannel) @ \(rec.suggestedWidth) MHz")
                    .font(.callout.weight(.semibold))
                Text(rec.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let cur = rec.currentChannel, !rec.isAlreadyOptimal,
                   let imp = rec.improvementScore, imp > 0.01 {
                    Text("Riduzione saturazione: \(String(format: "%.2f", imp)) (da \(cur) a \(rec.suggestedChannel))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if rec.isAlreadyOptimal {
                    Text("Sei già sul canale ottimale.")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
