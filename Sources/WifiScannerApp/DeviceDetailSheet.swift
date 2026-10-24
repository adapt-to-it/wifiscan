import SwiftUI
import WifiScanCore

@MainActor
@Observable
final class DeviceDetailViewModel {
    let device: LanDevice
    var customName: String

    var pingSamples: [PingSample] = []
    var pingStats: PingStats?
    var pingInFlight = false

    var ports: [PortScanResult] = []
    var portScanInFlight = false
    var portScanCompleted = false

    var wakeStatus: String?

    init(device: LanDevice) {
        self.device = device
        self.customName = device.customName ?? ""
    }

    func runPing() async {
        guard !pingInFlight else { return }
        pingInFlight = true
        defer { pingInFlight = false }
        let samples = await Pinger().ping(host: device.ip, count: 5, timeout: 1.0)
        pingSamples = samples
        pingStats = PingStats(samples: samples)
    }

    func runPortScan() async {
        guard !portScanInFlight else { return }
        portScanInFlight = true
        portScanCompleted = false
        defer { portScanInFlight = false }
        let result = await PortScanner().scan(host: device.ip, timeout: 0.5)
        ports = result
        portScanCompleted = true
    }

    func saveCustomName() {
        let trimmed = customName.trimmingCharacters(in: .whitespaces)
        guard let mac = device.mac else { return }
        PersistenceManager.shared.setCustomName(trimmed.isEmpty ? nil : trimmed, for: mac)
    }

    func runWake() async {
        guard let mac = device.mac else {
            wakeStatus = "Nessun MAC, impossibile inviare WoL."
            return
        }
        let ok = await WakeOnLAN.wake(mac: mac)
        wakeStatus = ok ? "Magic packet inviato a \(mac)." : "Invio WoL fallito."
    }
}

struct DeviceDetailSheet: View {
    @State var vm: DeviceDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: vm.device.deviceKind.systemImage)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.device.displayName == "—" ? vm.device.ip : vm.device.displayName)
                        .font(.title2.bold())
                    Text("\(vm.device.deviceKind.rawValue) · \(vm.device.ip)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fine") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NameEditor(vm: vm)
                    InfoGrid(device: vm.device)
                    PingPanel(vm: vm)
                    PortPanel(vm: vm)
                    if vm.device.mac != nil { WakePanel(vm: vm) }
                    if !vm.device.services.isEmpty { ServicesPanel(services: vm.device.services) }
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 720)
        .task { await vm.runPing() }
    }
}

// MARK: - Sotto-pannelli

private struct NameEditor: View {
    @Bindable var vm: DeviceDetailViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nome personalizzato", systemImage: "tag")
                .font(.headline)
            HStack {
                TextField("Es. NAS sala, Stampante studio…", text: $vm.customName)
                    .textFieldStyle(.roundedBorder)
                Button("Salva") {
                    vm.saveCustomName()
                }
                .disabled(vm.device.mac == nil)
            }
            if vm.device.mac == nil {
                Text("Nome custom disponibile solo per device con MAC noto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
    }
}

private struct InfoGrid: View {
    let device: LanDevice
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Informazioni", systemImage: "info.circle")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("IP", device.ip)
                row("MAC", device.mac ?? "—")
                row("Hostname", device.hostname ?? "—")
                row("Vendor", device.vendor ?? "—")
                row("Tipo", device.deviceKind.rawValue)
                if let first = device.firstSeen {
                    row("Primo avvistamento", Self.dateFormatter.string(from: first))
                }
                if device.seenCount > 0 {
                    row("Scan in cui è apparso", "\(device.seenCount)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()
}

private struct PingPanel: View {
    @Bindable var vm: DeviceDetailViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Latenza (ping)", systemImage: "dot.radiowaves.right")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.runPing() }
                } label: {
                    if vm.pingInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(vm.pingInFlight)
            }
            if let s = vm.pingStats {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        statCell("Min", s.minMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        statCell("Avg", s.avgMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        statCell("Max", s.maxMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        statCell("Jitter", s.jitterMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        statCell("Loss", String(format: "%.0f%%", s.lossPercent))
                    }
                }
            } else if vm.pingInFlight {
                Text("Ping in corso…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }
}

private struct PortPanel: View {
    @Bindable var vm: DeviceDetailViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Porte aperte", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.runPortScan() }
                } label: {
                    if vm.portScanInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Scansiona")
                    }
                }
                .disabled(vm.portScanInFlight)
            }
            if vm.portScanInFlight {
                Text("Scansione di \(PortScanner.commonPorts.count) porte in corso…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if vm.portScanCompleted {
                if vm.ports.isEmpty {
                    Text("Nessuna porta aperta tra quelle scansionate.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        ForEach(vm.ports, id: \.port) { p in
                            VStack(alignment: .center, spacing: 2) {
                                Text("\(p.port)")
                                    .font(.callout.monospacedDigit().weight(.medium))
                                Text(p.serviceName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.green.opacity(0.15))
                            }
                        }
                    }
                }
            } else {
                Text("Premi 'Scansiona' per testare \(PortScanner.commonPorts.count) porte comuni.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
    }
}

private struct WakePanel: View {
    @Bindable var vm: DeviceDetailViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Wake-on-LAN", systemImage: "power")
                    .font(.headline)
                Spacer()
                Button("Sveglia") {
                    Task { await vm.runWake() }
                }
                .disabled(vm.device.mac == nil)
            }
            if let s = vm.wakeStatus {
                Text(s)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Invia un magic packet UDP broadcast sulla LAN. Il device deve avere WoL abilitato in BIOS/Sistema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
    }
}

private struct ServicesPanel: View {
    let services: [BonjourService]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Servizi Bonjour pubblicati", systemImage: "bonjour")
                .font(.headline)
            ForEach(Array(services.enumerated()), id: \.offset) { _, svc in
                HStack(alignment: .firstTextBaseline) {
                    Text(svc.name).font(.callout).foregroundStyle(.primary)
                    Spacer()
                    Text(svc.serviceType).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let port = svc.port {
                        Text(":\(port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
    }
}
