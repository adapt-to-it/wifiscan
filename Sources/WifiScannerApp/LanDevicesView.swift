import AppKit
import SwiftUI
import WifiScanCore

struct LanDevicesView: View {
    let vm: LanScanViewModel
    @State private var selectedDevice: LanDevice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScanControlBar(vm: vm)
                PhaseIndicators(vm: vm)
                NetworkAlertsView(alerts: vm.alerts)
                if vm.devicesList.isEmpty && !vm.isScanning {
                    EmptyStateView(text: "Nessun dispositivo trovato. Premi “Scansiona LAN” per avviare la ricerca.")
                } else {
                    ForEach(networkGroups, id: \.label) { group in
                        if networkGroups.count > 1 {
                            Text("\(group.label) · \(group.devices.count)")
                                .font(.headline)
                        }
                        DevicesTable(devices: group.devices,
                                      isScanning: vm.isScanning,
                                      activityKnown: vm.activityKnown,
                                      onRemove: { vm.remove($0) },
                                      pendingCheck: { vm.cellPending(for: $0, cell: $1) },
                                      onSelect: { selectedDevice = $0 })
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $selectedDevice) { device in
            DeviceDetailSheet(vm: DeviceDetailViewModel(device: device))
        }
    }

    /// LAN locale per prima, poi il tailnet, poi le subnet remote.
    private var networkGroups: [(label: String, devices: [LanDevice])] {
        let grouped = Dictionary(grouping: vm.devicesList) { $0.network ?? "" }
        return grouped.keys.sorted { a, b in
            func rank(_ k: String) -> Int { k.isEmpty ? 0 : (k == LanDevice.tailnetLabel ? 1 : 2) }
            return (rank(a), a) < (rank(b), b)
        }.map { key in (key.isEmpty ? "LAN locale" : key, grouped[key] ?? []) }
    }
}

// MARK: - Control bar

struct ScanControlBar: View {
    let vm: LanScanViewModel
    @State private var confirmClear = false
    @State private var clearError: String?

    private func clear(systemARP: Bool) {
        Task { clearError = await vm.clearCache(systemARP: systemARP) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let s = vm.subnetLabel {
                    Text("Sottorete: \(s)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sottorete non rilevata")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if vm.isScanning {
                    Text("\(vm.devicesList.count) dispositivi scoperti finora…")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if vm.elapsed > 0 {
                    Text("\(vm.activeCount) attivi su \(vm.totalCount) rilevati in \(String(format: "%.1f", vm.elapsed))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Solo attivi", isOn: Binding(get: { vm.showOnlyActive }, set: { vm.showOnlyActive = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Nasconde le voci della cache ARP che non hanno risposto in questa scansione")
            Button {
                confirmClear = true
            } label: {
                Label("Svuota cache", systemImage: "trash")
            }
            .disabled(vm.isScanning)
            .confirmationDialog("Svuotare la cache dei dispositivi?", isPresented: $confirmClear) {
                Button("Svuota storico", role: .destructive) { clear(systemARP: false) }
                Button("Svuota storico e cache ARP di macOS…", role: .destructive) { clear(systemARP: true) }
            } message: {
                Text("Lo storico contiene la data del primo avvistamento e i nomi personalizzati: si perdono entrambi. La cache ARP di macOS conserva i dispositivi spenti per circa 20 minuti; svuotarla richiede la password di amministratore.")
            }
            .alert("Cache non svuotata", isPresented: Binding(get: { clearError != nil }, set: { if !$0 { clearError = nil } })) {
                Button("OK") { clearError = nil }
            } message: {
                Text(clearError ?? "")
            }
            Button {
                Task { await vm.scan() }
            } label: {
                HStack(spacing: 6) {
                    if vm.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.circle")
                    }
                    Text(vm.isScanning ? "In corso…" : "Scansiona LAN")
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(vm.isScanning)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        }
    }
}

// MARK: - Phase indicators

struct PhaseIndicators: View {
    let vm: LanScanViewModel

    var body: some View {
        HStack(spacing: 12) {
            PhaseChip(label: "ARP", progress: vm.arpProgress, systemImage: "list.bullet")
            PhaseChip(label: "Ping", progress: vm.pingProgress, systemImage: "dot.radiowaves.right")
            PhaseChip(label: "DNS", progress: vm.dnsProgress, systemImage: "text.bubble")
            PhaseChip(label: "Bonjour", progress: vm.bonjourProgress, systemImage: "antenna.radiowaves.left.and.right")
            PhaseChip(label: "UPnP", progress: vm.upnpProgress, systemImage: "tv.and.mediabox")
            PhaseChip(label: "Tailscale", progress: vm.tailscaleProgress, systemImage: "point.3.connected.trianglepath.dotted")
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

private struct PhaseChip: View {
    let label: String
    let progress: PhaseProgress
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: 16)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(progress.labelText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(.background.tertiary)
        }
    }

    private var icon: String {
        switch progress {
        case .done: return "checkmark.circle.fill"
        case .running, .inProgress: return systemImage
        case .idle: return systemImage
        }
    }

    private var iconColor: Color {
        switch progress {
        case .done: return Color.green
        case .running, .inProgress: return Color.accentColor
        case .idle: return Color.secondary
        }
    }
}

// MARK: - Table

struct DevicesTable: View {
    let devices: [LanDevice]
    let isScanning: Bool
    var activityKnown = true
    var onRemove: ((LanDevice) -> Void)? = nil
    let pendingCheck: (LanDevice, PendingCell) -> Bool
    var onSelect: ((LanDevice) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HeaderRow()
            ForEach(Array(devices.enumerated()), id: \.element.ip) { idx, dev in
                Button {
                    onSelect?(dev)
                } label: {
                    DeviceRow(device: dev, even: idx.isMultiple(of: 2),
                              activityKnown: activityKnown,
                              pendingCheck: pendingCheck)
                }
                .buttonStyle(.plain)
                .help("Apri dettagli · clic destro per copiare")
                .contextMenu {
                    CopyMenu(device: dev)
                    if let onRemove, !dev.isThisMac {
                        Divider()
                        Button("Rimuovi dalla lista e dallo storico", role: .destructive) { onRemove(dev) }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        }
    }

    private struct HeaderRow: View {
        var body: some View {
            HStack(spacing: 0) {
                headerCell("", width: 52, align: .center)
                headerCell("IP", width: 120, align: .leading)
                headerCell("HOSTNAME", width: 200, align: .leading)
                headerCell("MAC", width: 160, align: .leading)
                headerCell("VENDOR", width: 160, align: .leading)
                headerCell("TIPO", width: 130, align: .leading)
                headerCell("SERVIZI", width: 0, align: .leading)
                Spacer()
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
                .frame(width: width > 0 ? width : nil, alignment: align)
        }
    }

    private struct DeviceRow: View {
        let device: LanDevice
        let even: Bool
        let activityKnown: Bool
        let pendingCheck: (LanDevice, PendingCell) -> Bool
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ActivityLED(active: device.isActive, known: activityKnown)
                    Image(systemName: device.deviceKind.systemImage)
                        .foregroundStyle(device.isThisMac ? Color.accentColor : Color.secondary)
                }
                .frame(width: 52, alignment: .center)

                HStack(spacing: 4) {
                    Text(device.ip)
                        .font(.callout.monospacedDigit().weight(device.isThisMac ? .semibold : .regular))
                    if hovering {
                        Button {
                            Pasteboard.copy(device.ip)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copia indirizzo IP")
                    }
                }
                .frame(width: 120, alignment: .leading)

                HStack(spacing: 6) {
                    if let hostname = device.customName ?? device.hostname ?? device.model, !hostname.isEmpty {
                        Text(hostname).lineLimit(1)
                    } else if pendingCheck(device, .hostname) {
                        PendingDots()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                    if device.isThisMac {
                        BadgeView(text: "TU", tint: .accentColor)
                    }
                    if device.isNew && !device.isThisMac {
                        BadgeView(text: "NUOVO", tint: .orange)
                    }
                    if let mac = device.mac, MACAddress.isRandomized(mac) {
                        BadgeView(text: "MAC CASUALE", tint: .purple)
                            .help("MAC privato generato dal dispositivo (iOS, Android, Windows): il vendor non è identificabile e può cambiare nel tempo.")
                    }
                }
                .frame(width: 200, alignment: .leading)

                HStack {
                    if let mac = device.mac {
                        Text(mac).font(.callout.monospaced()).foregroundStyle(.secondary)
                    } else if pendingCheck(device, .mac) {
                        PendingDots()
                    } else {
                        Text("—").foregroundStyle(.secondary).font(.callout)
                    }
                }
                .frame(width: 160, alignment: .leading)

                HStack {
                    if let vendor = device.vendor {
                        Text(vendor).lineLimit(1)
                    } else if pendingCheck(device, .vendor) {
                        PendingDots()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, alignment: .leading)

                Text(device.deviceKind.rawValue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)

                HStack {
                    if !device.services.isEmpty {
                        ServicesView(services: device.services)
                    } else if pendingCheck(device, .services) {
                        PendingDots()
                    } else {
                        Text("—").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(even ? Color.clear : Color.secondary.opacity(0.05))
            .opacity(device.isActive || !activityKnown ? 1 : 0.55)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    private struct CopyMenu: View {
        let device: LanDevice
        var body: some View {
            Button("Copia indirizzo IP") { Pasteboard.copy(device.ip) }
            if let mac = device.mac { Button("Copia MAC") { Pasteboard.copy(mac) } }
            if let name = device.customName ?? device.hostname, !name.isEmpty {
                Button("Copia hostname") { Pasteboard.copy(name) }
            }
        }
    }

    private struct ServicesView: View {
        let services: [BonjourService]
        var body: some View {
            HStack(spacing: 4) {
                ForEach(services.prefix(4), id: \.self) { svc in
                    Text(shortLabel(for: svc.serviceType))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background { Capsule().fill(Color.secondary.opacity(0.15)) }
                        .foregroundStyle(.secondary)
                }
                if services.count > 4 {
                    Text("+\(services.count - 4)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private func shortLabel(for serviceType: String) -> String {
            let trimmed = serviceType.hasPrefix("_") ? String(serviceType.dropFirst()) : serviceType
            return trimmed.split(separator: ".").first.map(String.init) ?? serviceType
        }
    }
}

// MARK: - Shared bits

private struct BadgeView: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background { Capsule().fill(tint.opacity(0.20)) }
            .foregroundStyle(tint)
    }
}

private struct PendingDots: View {
    @State private var phase: Int = 0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(phase == i ? 0.8 : 0.25))
                    .frame(width: 4, height: 4)
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// LED di stato: verde lampeggiante se il dispositivo ha risposto in questa scansione,
/// grigio vuoto se è solo nella cache ARP. Durante il ping sweep lo stato non è ancora noto.
struct ActivityLED: View {
    let active: Bool
    let known: Bool
    @State private var lit = false

    var body: some View {
        Group {
            if active {
                Circle()
                    .fill(Color.green)
                    .shadow(color: .green.opacity(lit ? 0.9 : 0.2), radius: lit ? 4 : 1)
                    .opacity(lit ? 1 : 0.45)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
                    }
                    .help("Attivo: ha risposto in questa scansione")
            } else if known {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                    .help("Non ha risposto: è solo nella cache ARP di macOS o ignora il ping")
            } else {
                Circle().fill(Color.secondary.opacity(0.2))
            }
        }
        .frame(width: 8, height: 8)
    }
}
