import SwiftUI
import WifiScanCore

struct NetworksView: View {
    let vm: ScanViewModel

    var body: some View {
        let nets = vm.lastResult?.networks ?? []
        let selfIdx = vm.lastResult?.selfIndices ?? []
        let sorted = nets.enumerated().sorted { $0.element.rssi > $1.element.rssi }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if nets.isEmpty {
                    EmptyStateView(text: "Nessuna rete rilevata. Esegui uno scan.")
                } else {
                    NetworkTableHeader()
                    ForEach(Array(sorted.enumerated()), id: \.element.element.id) { rowIdx, pair in
                        let (origIdx, net) = pair
                        NetworkRow(net: net, isSelf: selfIdx.contains(origIdx), even: rowIdx.isMultiple(of: 2))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NetworkTableHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            headerCell("SSID", width: 240, align: .leading)
            headerCell("Banda", width: 80)
            headerCell("Canale", width: 70)
            headerCell("Largh.", width: 80)
            headerCell("Wi-Fi", width: 60)
            headerCell("RSSI", width: 90)
            headerCell("BSSID", width: 160, align: .leading)
            headerCell("Sicurezza", width: 180, align: .leading)
            headerCell("Client", width: 70)
            headerCell("Utilizzo", width: 80)
            Spacer()
            headerCell("", width: 80, align: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func headerCell(_ s: String, width: CGFloat, align: Alignment = .center) -> some View {
        Text(s)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(width: width, alignment: align)
    }
}

struct NetworkRow: View {
    let net: ScannedNetwork
    let isSelf: Bool
    let even: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: net.band == .ghz24 ? "antenna.radiowaves.left.and.right" : "wifi")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                Text(net.ssid)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 240, alignment: .leading)

            Text(net.band.rawValue).frame(width: 80)
            Text("\(net.channel)").monospacedDigit().frame(width: 70)
            Text("\(net.width) MHz").monospacedDigit().frame(width: 80)
            Text(wifiText).monospacedDigit().frame(width: 60)
            Text("\(net.rssi) dBm")
                .monospacedDigit()
                .foregroundStyle(rssiColor)
                .frame(width: 90)
            Text(net.bssid)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(securityText)
                .foregroundStyle(securityWarn ? Color.orange : Color.primary)
                .frame(width: 180, alignment: .leading)
            Text(clientText).monospacedDigit().frame(width: 70)
            Text(utilText).monospacedDigit().frame(width: 80)
            Spacer()
            HStack(spacing: 6) {
                if isSelf {
                    Label("TU", systemImage: "dot.radiowaves.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            Capsule().fill(Color.accentColor.opacity(0.18))
                        }
                        .foregroundStyle(.tint)
                }
                if net.rssi < Scoring.rssiFloor {
                    Text("debole")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background { Capsule().fill(Color.secondary.opacity(0.15)) }
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(even ? Color.clear : Color.secondary.opacity(0.05))
    }

    private var rssiColor: Color {
        if net.rssi >= -55 { return .green }
        if net.rssi >= -75 { return .yellow }
        return .red
    }

    private var wifiText: String {
        guard let gen = net.beacon?.wifiGeneration else { return "—" }
        return "\(gen)"
    }

    private var securityText: String {
        guard let sec = net.beacon?.security, !sec.isEmpty else { return "—" }
        return sec.joined(separator: "/")
    }

    /// Arancione con TKIP o con il solo WPA (senza AKM moderne).
    private var securityWarn: Bool {
        guard let beacon = net.beacon else { return false }
        return beacon.hasTKIP || beacon.security == ["WPA"]
    }

    private var clientText: String {
        guard let count = net.beacon?.stationCount else { return "—" }
        return "\(count)"
    }

    private var utilText: String {
        guard let util = net.beacon?.channelUtilization else { return "—" }
        return "\(Int((util * 100).rounded()))%"
    }
}
