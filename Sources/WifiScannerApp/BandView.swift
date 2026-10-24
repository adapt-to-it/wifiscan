import SwiftUI
import Charts
import WifiScanCore

struct BandView: View {
    let vm: ScanViewModel
    let band: ScannedNetwork.Band

    var body: some View {
        let loads = vm.loads(for: band)
        let connectedCh = vm.lastResult?.connected?.channel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loads.isEmpty {
                    EmptyStateView(text: "Nessun dato per \(band.rawValue). Esegui uno scan.")
                } else {
                    SaturationChart(loads: loads, connectedChannel: connectedCh, band: band)
                    ChannelTable(loads: loads, connectedChannel: connectedCh, band: band)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Chart

struct SaturationChart: View {
    let loads: [ChannelLoad]
    let connectedChannel: Int?
    let band: ScannedNetwork.Band

    var body: some View {
        let maxScore = max(loads.map(\.saturationScore).max() ?? 1.0, 0.1)
        VStack(alignment: .leading, spacing: 8) {
            Text("Saturazione canali \(band.rawValue)")
                .font(.headline)
            Chart {
                ForEach(loads, id: \.id) { load in
                    BarMark(
                        x: .value("Canale", String(load.channel)),
                        y: .value("Saturazione", load.saturationScore)
                    )
                    .foregroundStyle(by: .value("Livello", scoreCategory(load.saturationScore, max: maxScore)))
                    .annotation(position: .top, alignment: .center) {
                        if load.channel == connectedChannel {
                            Image(systemName: "dot.radiowaves.right")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .chartForegroundStyleScale([
                "libero":  Color.green.opacity(0.85),
                "medio":   Color.yellow.opacity(0.85),
                "saturo":  Color.red.opacity(0.85),
            ])
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: loads.count)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(centered: true)
                }
            }
            .frame(height: 280)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private func scoreCategory(_ score: Double, max: Double) -> String {
        let ratio = score / max
        if ratio < 0.25 { return "libero" }
        if ratio < 0.6 { return "medio" }
        return "saturo"
    }
}

// MARK: - Tabella canali

struct ChannelTable: View {
    let loads: [ChannelLoad]
    let connectedChannel: Int?
    let band: ScannedNetwork.Band

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                cell("Ch", width: 60, bold: true, align: .leading)
                cell("Pri", width: 50, bold: true)
                cell("Ovl", width: 50, bold: true)
                cell("Adj", width: 50, bold: true)
                cell("Score", width: 80, bold: true)
                cell("Tipo", width: 140, bold: true, align: .leading)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(.background.tertiary)

            ForEach(Array(loads.sorted(by: { $0.saturationScore > $1.saturationScore }).enumerated()), id: \.element.id) { idx, load in
                let isMine = load.channel == connectedChannel
                let cls = band == .ghz5 ? ChannelClass.classify(load.channel) : .nonDFS
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        if isMine {
                            Image(systemName: "dot.radiowaves.right")
                                .foregroundStyle(.tint)
                                .font(.caption)
                        }
                        Text("\(load.channel)")
                            .font(.callout.monospacedDigit().weight(isMine ? .semibold : .regular))
                    }
                    .frame(width: 60, alignment: .leading)

                    cell("\(load.primaryNetworks.count)", width: 50)
                    cell("\(load.overlapNetworks.count)", width: 50)
                    cell("\(load.adjacentNetworks.count)", width: 50)
                    Text(String(format: "%.2f", load.saturationScore))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(scoreColor(load.saturationScore))
                        .frame(width: 80, alignment: .center)
                    if !cls.label.isEmpty {
                        Text(cls.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                Capsule().fill(cls == .dfsTerminal ? Color.orange.opacity(0.18) : Color.yellow.opacity(0.18))
                            }
                            .foregroundStyle(cls == .dfsTerminal ? Color.orange : Color.yellow)
                            .frame(width: 140, alignment: .leading)
                    } else {
                        Color.clear.frame(width: 140)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(idx.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        }
    }

    @ViewBuilder
    private func cell(_ s: String, width: CGFloat, bold: Bool = false, align: Alignment = .center) -> some View {
        Text(s)
            .font(.callout.monospacedDigit().weight(bold ? .semibold : .regular))
            .foregroundStyle(bold ? .secondary : .primary)
            .frame(width: width, alignment: align)
    }

    private func scoreColor(_ score: Double) -> Color {
        let maxScore = max(loads.map(\.saturationScore).max() ?? 1.0, 0.1)
        let ratio = score / maxScore
        if ratio < 0.25 { return .green }
        if ratio < 0.6 { return .yellow }
        return .red
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(40)
    }
}
