import AppKit
import Foundation
import Observation
import WifiScanCore

@MainActor
@Observable
final class LanScanViewModel {
    enum State: Sendable {
        case idle
        case scanning
        case done
        case failed(String)
    }

    var state: State = .idle
    var subnet: LocalSubnet?
    var elapsed: TimeInterval = 0

    /// Mappa interna IP→device. UI legge `devicesList` (ordinata).
    private var devicesByIP: [String: LanDevice] = [:]
    /// Snapshot ordinata. Aggiornata throttled per evitare flicker.
    private(set) var devicesList: [LanDevice] = []

    /// Stato per ogni fase: completed/total/done.
    var arpProgress: PhaseProgress = .idle
    var pingProgress: PhaseProgress = .idle
    var dnsProgress: PhaseProgress = .idle
    var bonjourProgress: PhaseProgress = .idle
    var tailscaleProgress: PhaseProgress = .idle
    var upnpProgress: PhaseProgress = .idle
    var alerts: [NetworkAlert] = []

    private let scanner = LanScanner()
    private var currentTask: Task<Void, Never>?
    private var startTime: Date?
    private var pendingUpdateTask: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var subnetLabel: String? {
        guard let s = subnet else { return nil }
        return "\(s.networkAddress)/\(s.prefixLength) · \(s.interface)"
    }

    /// True se almeno una fase non è ancora completata (per spinner cella).
    var isEnrichmentInProgress: Bool {
        isScanning
    }

    func cancelScan() {
        currentTask?.cancel()
        currentTask = nil
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
    }

    func scan() async {
        cancelScan()
        startTime = Date()
        devicesByIP.removeAll()
        devicesList = []
        arpProgress = .idle
        pingProgress = .idle
        dnsProgress = .idle
        bonjourProgress = .idle
        tailscaleProgress = .idle
        upnpProgress = .idle
        alerts = []
        state = .scanning

        guard let subnet = LocalNetworkInspector.detectActiveSubnet(preferring: "en0") else {
            state = .failed("Impossibile determinare la sottorete. Verifica di essere connesso al Wi-Fi.")
            return
        }
        self.subnet = subnet

        let stream = scanner.scanStream(subnet: subnet)
        let task = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                await self?.handle(event)
            }
        }
        currentTask = task
        await task.value
    }

    // MARK: - Event handling

    private func handle(_ event: LanScanEvent) async {
        switch event {
        case .started:
            break  // già impostato

        case .deviceUpsert(let device):
            // Merge nel dizionario interno
            if let existing = devicesByIP[device.ip] {
                devicesByIP[device.ip] = existing.merged(with: device)
            } else {
                devicesByIP[device.ip] = device
            }
            scheduleListUpdate()

        case .phaseUpdate(let phase, let completed, let total):
            updatePhase(phase, completed: completed, total: total, done: false)

        case .phaseDone(let phase):
            updatePhase(phase, completed: nil, total: nil, done: true)

        case .alerts(let found):
            alerts = found

        case .finished(let result):
            elapsed = result.elapsed
            // Force final list update
            applyListNow()
            state = .done
        }
    }

    private func updatePhase(_ phase: LanScanPhase, completed: Int?, total: Int?, done: Bool) {
        let new: PhaseProgress
        if done {
            new = .done
        } else if let c = completed, let t = total {
            new = .inProgress(completed: c, total: t)
        } else {
            new = .running
        }
        switch phase {
        case .arp: arpProgress = new
        case .ping: pingProgress = new
        case .dns: dnsProgress = new
        case .bonjour: bonjourProgress = new
        case .tailscale: tailscaleProgress = new
        case .upnp: upnpProgress = new
        }
    }

    // MARK: - Throttle list updates (max ~10/s)

    private func scheduleListUpdate() {
        guard pendingUpdateTask == nil else { return }
        pendingUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms = 10Hz max
            await MainActor.run {
                self?.applyListNow()
                self?.pendingUpdateTask = nil
            }
        }
    }

    /// Mostra solo i dispositivi che hanno risposto nell'ultima scansione.
    var showOnlyActive = false {
        didSet { applyListNow() }
    }

    var activeCount: Int { devicesByIP.values.filter(\.isActive).count }
    var totalCount: Int { devicesByIP.count }

    /// Lo stato attivo è definitivo solo a ping finito: prima le voci ARP non hanno ancora risposto.
    var activityKnown: Bool { pingProgress == .done || !isScanning }

    /// Toglie un dispositivo dalla lista e dallo storico.
    func remove(_ device: LanDevice) {
        devicesByIP[device.ip] = nil
        if let mac = device.mac { PersistenceManager.shared.delete(mac: mac) }
        alerts.removeAll { $0.id.hasSuffix("-\(device.ip)") }
        applyListNow()
    }

    /// Svuota lo storico dei dispositivi e toglie dalla lista quelli non attivi.
    /// Con `systemARP` svuota anche la cache ARP di macOS, che richiede la password di amministratore.
    func clearCache(systemARP: Bool) async -> String? {
        if systemARP, let error = await Self.flushSystemARP() { return error }
        PersistenceManager.shared.deleteAll()
        devicesByIP = devicesByIP.filter { $0.value.isActive }
        alerts.removeAll { $0.kind == .newDevice }
        applyListNow()
        return nil
    }

    private nonisolated static func flushSystemARP() async -> String? {
        await Task.detached {
            let script = "do shell script \"/usr/sbin/arp -a -d\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            guard let error else { return nil }
            // -128: l'utente ha annullato la richiesta della password.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Operazione annullata." }
            return error[NSAppleScript.errorMessage] as? String ?? "Impossibile svuotare la cache ARP."
        }.value
    }

    private func applyListNow() {
        devicesList = devicesByIP.values.filter { !showOnlyActive || $0.isActive || !activityKnown }.sorted {
            (LocalSubnet.ipv4ToUInt32($0.ip) ?? 0) < (LocalSubnet.ipv4ToUInt32($1.ip) ?? 0)
        }
    }

    /// Quante fasi devono ancora popolare la cella?
    func cellPending(for device: LanDevice, cell: PendingCell) -> Bool {
        guard isScanning else { return false }
        // Reti remote: MAC, vendor e Bonjour non arrivano attraverso la VPN.
        if device.network != nil && cell != .hostname { return false }
        switch cell {
        case .hostname:
            return device.hostname == nil && dnsProgress != .done
        case .vendor:
            return device.vendor == nil && device.mac != nil
        case .services:
            return device.services.isEmpty && bonjourProgress != .done
        case .mac:
            return device.mac == nil && (pingProgress != .done || arpProgress != .done)
        }
    }
}

enum PendingCell: Sendable {
    case hostname, vendor, services, mac
}

enum PhaseProgress: Equatable, Sendable {
    case idle
    case running
    case inProgress(completed: Int, total: Int)
    case done

    var isActive: Bool {
        switch self {
        case .running, .inProgress: return true
        default: return false
        }
    }

    var labelText: String {
        switch self {
        case .idle: return "—"
        case .running: return "in corso…"
        case .inProgress(let c, let t): return "\(c)/\(t)"
        case .done: return "✓"
        }
    }

    var fraction: Double {
        if case .inProgress(let c, let t) = self, t > 0 {
            return Double(c) / Double(t)
        }
        return self == .done ? 1.0 : 0.0
    }
}
