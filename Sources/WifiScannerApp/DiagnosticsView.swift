import SwiftUI
import Charts
import WifiScanCore

struct DiagnosticsView: View {
    let vm: DiagnosticsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConnectivityCard(vm: vm)
                LatencyTimelineCard(vm: vm)
                PublicInfoCard(vm: vm)
                NetworkQualityCard(vm: vm)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await vm.runConnectivityCheck()
            await vm.loadPublicInfo()
            vm.startLiveMonitoring()
        }
        .onDisappear {
            vm.stopLiveMonitoring()
        }
    }
}

// MARK: - Connettività

private struct ConnectivityCard: View {
    let vm: DiagnosticsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Connettività", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.runConnectivityCheck() }
                } label: {
                    if vm.checkingConnectivity {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(vm.checkingConnectivity)
            }

            HStack(spacing: 24) {
                hopColumn(title: "Gateway", subtitle: vm.gatewayIP ?? "—", stats: vm.gatewayPing)
                Divider().frame(height: 60)
                hopColumn(title: "Cloudflare", subtitle: "1.1.1.1", stats: vm.publicPing1111)
                Divider().frame(height: 60)
                hopColumn(title: "Google", subtitle: "8.8.8.8", stats: vm.publicPing8888)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private func hopColumn(title: String, subtitle: String, stats: PingStats?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stats.flatMap { color(for: $0) } ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(title).font(.callout.weight(.semibold))
            }
            Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let s = stats, let avg = s.avgMs {
                Text(String(format: "%.0f ms", avg))
                    .font(.title2.monospacedDigit().weight(.medium))
                if s.lossPercent > 0 {
                    Text(String(format: "%.0f%% loss", s.lossPercent))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else if stats != nil {
                Text("Timeout").font(.caption).foregroundStyle(.red)
            } else {
                Text("—").font(.title2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func color(for stats: PingStats) -> Color {
        guard let avg = stats.avgMs else { return .red }
        if stats.lossPercent > 5 { return .red }
        if avg < 30 { return .green }
        if avg < 100 { return .yellow }
        return .orange
    }
}

// MARK: - Timeline grafico

private struct LatencyTimelineCard: View {
    let vm: DiagnosticsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Latenza al gateway (live)", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                if vm.liveMonitoringActive {
                    Label("Live", systemImage: "dot.radiowaves.right")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background { Capsule().fill(Color.green.opacity(0.2)) }
                        .foregroundStyle(.green)
                }
            }
            if vm.pingTimeline.isEmpty {
                Text("Avvio monitoraggio…").foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                Chart {
                    ForEach(Array(vm.pingTimeline.enumerated()), id: \.offset) { i, sample in
                        if let rtt = sample.rttMillis {
                            LineMark(
                                x: .value("Sec", -Double(vm.pingTimeline.count - 1 - i)),
                                y: .value("RTT", rtt)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.tint)
                            AreaMark(
                                x: .value("Sec", -Double(vm.pingTimeline.count - 1 - i)),
                                y: .value("RTT", rtt)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.tint.opacity(0.18))
                        } else {
                            // timeout = marker rosso a 0
                            PointMark(
                                x: .value("Sec", -Double(vm.pingTimeline.count - 1 - i)),
                                y: .value("RTT", 0)
                            )
                            .foregroundStyle(.red)
                            .symbol(.diamond)
                        }
                    }
                }
                .chartXAxisLabel("Secondi (ora ← passato)")
                .chartYAxisLabel("ms")
                .frame(height: 200)
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

// MARK: - IP pubblico

private struct PublicInfoCard: View {
    let vm: DiagnosticsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Rete pubblica", systemImage: "globe")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.loadPublicInfo() }
                } label: {
                    if vm.loadingPublicInfo {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(vm.loadingPublicInfo)
            }
            if let info = vm.publicInfo {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    if let ip = info.ip {
                        gridRow("IP pubblico", ip)
                    }
                    if let isp = info.isp {
                        gridRow("ISP / Org", isp)
                    }
                    if let city = info.city, let country = info.country {
                        gridRow("Posizione apparente", "\(city), \(country)")
                    }
                }
            } else {
                Text("Caricamento…").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private func gridRow(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
            Text(v).monospaced().textSelection(.enabled)
        }
    }
}

// MARK: - Qualità della rete

private struct NetworkQualityCard: View {
    let vm: DiagnosticsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Qualità della rete", systemImage: "gauge.with.needle")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.runNetworkQuality() }
                } label: {
                    if vm.networkQualityRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("In corso…")
                        }
                    } else {
                        Text("Avvia")
                    }
                }
                .disabled(vm.networkQualityRunning)
            }

            if let e = vm.networkQualityError {
                Text(e)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let r = vm.networkQuality {
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    metric("Download", String(format: "%.1f", r.downloadMbps), "Mbit/s")
                    metric("Upload", String(format: "%.1f", r.uploadMbps), "Mbit/s")
                    metric("Latenza base", String(format: "%.0f", r.baseRTTms), "ms")
                    metric("Responsiveness", String(format: "%.0f", r.responsivenessRPM), "RPM · \(r.responsivenessLabel)")
                }
                Text("RPM basso indica bufferbloat: la rete rallenta molto sotto carico.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Misura download, upload, latenza e responsiveness (~20 s). Premi 'Avvia'.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tint)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
