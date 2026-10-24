import Foundation

// MARK: - Modello dispositivo (invariato)

/// Dispositivo trovato sulla LAN, aggregato da tutte le fonti.
public struct LanDevice: Sendable, Identifiable, Hashable {
    public var id: String { ip }
    public let ip: String
    public var mac: String?
    public var vendor: String?
    public var hostname: String?
    public var services: [BonjourService]
    public var isThisMac: Bool
    public var customName: String?
    public var isNew: Bool
    public var firstSeen: Date?
    public var seenCount: Int
    /// Rete di provenienza: nil per la LAN locale, altrimenti es. "Tailscale" o "192.168.1.0/24 via ts-exit".
    public var network: String?
    /// Nome o modello dichiarato via UPnP/SSDP, es. "[TV] Samsung Q60".
    public var model: String?
    /// Ha risposto in questa scansione (ping, Bonjour, SSDP, Tailscale online). Falso per le voci
    /// lette solo dalla cache ARP, che macOS conserva per circa 20 minuti dopo l'ultimo contatto.
    public var isActive: Bool

    public init(ip: String, mac: String? = nil, vendor: String? = nil,
                hostname: String? = nil, services: [BonjourService] = [],
                isThisMac: Bool = false, customName: String? = nil,
                isNew: Bool = false, firstSeen: Date? = nil, seenCount: Int = 0,
                network: String? = nil, model: String? = nil, isActive: Bool = false) {
        self.ip = ip
        self.mac = mac
        self.vendor = vendor
        self.hostname = hostname
        self.services = services
        self.isThisMac = isThisMac
        self.customName = customName
        self.isNew = isNew
        self.firstSeen = firstSeen
        self.seenCount = seenCount
        self.network = network
        self.model = model
        self.isActive = isActive
    }

    public var displayName: String {
        customName ?? hostname ?? model ?? "—"
    }

    /// Tipo dispositivo dedotto da vendor + servizi + hostname (best-effort).
    public var deviceKind: DeviceKind {
        let serviceTypes = services.map(\.serviceType)
        if serviceTypes.contains(where: { $0.contains("googlecast") }) { return .tv }
        if serviceTypes.contains(where: { $0.contains("airplay") || $0.contains("raop") }) { return .tv }
        if serviceTypes.contains(where: { $0.contains("ipp") || $0.contains("printer") || $0.contains("pdl") }) { return .printer }
        if serviceTypes.contains(where: { $0.contains("hap") }) { return .smartHome }
        if serviceTypes.contains(where: { $0.contains("apple-mobdev") }) { return .phone }
        if serviceTypes.contains(where: { $0.contains("companion-link") }) { return .computer }

        if network == Self.tailnetLabel, let os = vendor?.lowercased() {
            if os.contains("ios") { return .phone }
            if os.contains("linux") { return .server }
            if os.contains("macos") || os.contains("windows") { return .computer }
        }

        let h = Self.norm(hostname ?? "")
        if h.contains("iphone") || h.contains("ipad") || h.contains("android") || h.hasPrefix("honor") { return .phone }
        if h.contains("macbook") || h.contains("imac") || h.contains("desktop") || h.contains("laptop") || h.contains("workstation") { return .computer }
        if h.contains("appletv") || h.contains("homepod") { return .tv }
        if h.contains("printer") || h.contains("hpprinter") || h.contains("epson") || h.contains("brother") { return .printer }
        if h.contains("rodecaster") || h.contains("rode") { return .audio }
        if h.contains("acquario") || h.contains("server") || h.contains("nas") || h.contains("proxmox") { return .server }

        let v = Self.norm(vendor ?? "")
        if v.contains("proxmox") { return .server }
        if v.contains("raspberrypi") || v.contains("raspberry") { return .server }
        if v.contains("vantiva") || v.contains("technicolor") || v.contains("arcadyan") || v.contains("sagemcom") || v.contains("zyxel") { return .router }
        if v.contains("apple") { return .computer }
        if v.contains("google") || v.contains("nest") { return .router }
        if v.contains("amazon") { return .smartHome }
        if v.contains("samsung") || v.contains("lgelectronics") || v.contains("sony") || v.contains("philips") || v.contains("universalglobal") || v.contains("vizio") || v.contains("hisense") { return .tv }
        if v.contains("xiaomi") || v.contains("huaweitechnologies") || v.contains("huawei") || v.contains("honor") || v.contains("oneplus") || v.contains("oppo") { return .phone }
        if v.contains("tplink") || v.contains("netgear") || v.contains("asustek") || v.contains("asus") ||
           v.contains("linksys") || v.contains("ubiquiti") || v.contains("mikrotik") || v.contains("fritz") ||
           v.contains("avm") || v.contains("dlink") {
            return .router
        }
        if v.contains("intelcorporate") || v.contains("intel") || v.contains("lenovo") || v.contains("dellinc") ||
           v.contains("dell") || v.contains("hpinc") || v.contains("hewlettpackard") ||
           v.contains("realtek") || v.contains("lcfcelectron") || v.contains("lcfc") || v.contains("compal") {
            return .computer
        }
        if v.contains("fnlinktechnology") || v.contains("fnlink") || v.contains("rodemicrophones") || v.contains("rode") ||
           v.contains("sonos") || v.contains("bose") {
            return .audio
        }
        return .unknown
    }

    /// Valore di `network` per i nodi del tailnet.
    public static let tailnetLabel = "Tailscale"

    private static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Merge: combina i campi non-nil di `other` sopra i nostri.
    public func merged(with other: LanDevice) -> LanDevice {
        LanDevice(
            ip: ip,
            mac: other.mac ?? mac,
            vendor: other.vendor ?? vendor,
            hostname: other.hostname ?? hostname,
            services: (services + other.services).uniqued(),
            isThisMac: isThisMac || other.isThisMac,
            customName: other.customName ?? customName,
            isNew: other.isNew || isNew,
            firstSeen: firstSeen ?? other.firstSeen,
            seenCount: max(seenCount, other.seenCount),
            network: other.network ?? network,
            model: other.model ?? model,
            isActive: isActive || other.isActive
        )
    }
}

extension Array where Element == BonjourService {
    fileprivate func uniqued() -> [BonjourService] {
        var seen = Set<String>()
        var result: [BonjourService] = []
        for s in self {
            let k = "\(s.name)|\(s.serviceType)|\(s.port ?? 0)"
            if !seen.contains(k) {
                seen.insert(k); result.append(s)
            }
        }
        return result
    }
}

public enum DeviceKind: String, Sendable {
    case computer    = "Computer"
    case phone       = "Smartphone"
    case tablet      = "Tablet"
    case router      = "Router"
    case tv          = "TV / Speaker"
    case printer     = "Stampante"
    case smartHome   = "Smart Home"
    case server      = "Server / VM"
    case audio       = "Audio"
    case unknown     = "Generico"

    public var systemImage: String {
        switch self {
        case .computer:  "laptopcomputer"
        case .phone:     "iphone"
        case .tablet:    "ipad"
        case .router:    "wifi.router.fill"
        case .tv:        "tv.fill"
        case .printer:   "printer.fill"
        case .smartHome: "homekit"
        case .server:    "server.rack"
        case .audio:     "hifispeaker.fill"
        case .unknown:   "circle.dotted"
        }
    }
}

// MARK: - Eventi stream

/// Eventi emessi durante uno scan LAN streaming.
public enum LanScanEvent: Sendable {
    /// Subnet rilevata, scan partito.
    case started(subnet: LocalSubnet)
    /// Dispositivo nuovo o aggiornato (merge per IP nel consumer).
    case deviceUpsert(LanDevice)
    /// Una fase ha cambiato stato (per UI progress).
    case phaseUpdate(LanScanPhase, completed: Int, total: Int)
    /// Una fase è completata.
    case phaseDone(LanScanPhase)
    /// Allarmi calcolati a fine scan (gateway, conflitti IP, nuovi device).
    case alerts([NetworkAlert])
    /// Scan terminato: tutte le fasi completate (o cancellate).
    case finished(LanScanResult)
}

public enum LanScanPhase: String, Sendable {
    case arp = "ARP"
    case ping = "Ping sweep"
    case dns = "DNS reverse"
    case bonjour = "Bonjour"
    case tailscale = "Tailscale"
    case upnp = "UPnP"
}

// MARK: - Risultato finale (per chi vuole l'aggregato)

public struct LanScanResult: Sendable {
    public let subnet: LocalSubnet
    public let devices: [LanDevice]
    public let elapsed: TimeInterval
    public let timestamp: Date

    public init(subnet: LocalSubnet, devices: [LanDevice], elapsed: TimeInterval, timestamp: Date) {
        self.subnet = subnet
        self.devices = devices
        self.elapsed = elapsed
        self.timestamp = timestamp
    }
}

// MARK: - Vecchio progress (mantenuto per backward-compat con CLI/altri caller)

public struct LanScanProgress: Sendable {
    public enum Phase: String, Sendable {
        case pinging = "Ping sweep"
        case arp = "Lettura ARP"
        case dns = "Risoluzione hostname"
        case bonjour = "Discovery servizi"
        case done = "Completato"
    }
    public let phase: Phase
    public let completed: Int
    public let total: Int

    public init(phase: Phase, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}

// MARK: - Scanner

public final class LanScanner: @unchecked Sendable {
    public init() {}

    // MARK: API streaming (nuova, preferita)

    /// Esegue scan emettendo eventi incrementali. La tabella si popola progressivamente.
    /// Lo stream termina con `.finished(result)` o viene chiuso silenziosamente in caso di cancellation.
    public func scanStream(subnet: LocalSubnet,
                           pingTimeout: TimeInterval = 0.8,
                           bonjourDuration: TimeInterval = 4.0) -> AsyncStream<LanScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await self.runScan(subnet: subnet,
                                   pingTimeout: pingTimeout,
                                   bonjourDuration: bonjourDuration,
                                   continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: API backward-compat (aggregato finale)

    @available(*, deprecated, message: "Use scanStream(subnet:) per UI live")
    public func scan(subnet: LocalSubnet,
                     pingTimeout: TimeInterval = 0.8,
                     bonjourDuration: TimeInterval = 3.0,
                     progress: (@Sendable (LanScanProgress) -> Void)? = nil) async -> LanScanResult {
        var lastResult: LanScanResult?
        for await event in scanStream(subnet: subnet,
                                       pingTimeout: pingTimeout,
                                       bonjourDuration: bonjourDuration) {
            switch event {
            case .phaseUpdate(let phase, let c, let t):
                progress?(.init(phase: mapPhase(phase), completed: c, total: t))
            case .finished(let r):
                lastResult = r
            default:
                break
            }
        }
        return lastResult ?? LanScanResult(subnet: subnet, devices: [], elapsed: 0, timestamp: Date())
    }

    private func mapPhase(_ p: LanScanPhase) -> LanScanProgress.Phase {
        switch p {
        case .arp: return .arp
        case .ping: return .pinging
        case .dns: return .dns
        case .bonjour: return .bonjour
        case .tailscale: return .pinging
        case .upnp: return .bonjour
        }
    }

    // MARK: - Core implementation

    private func runScan(subnet: LocalSubnet,
                         pingTimeout: TimeInterval,
                         bonjourDuration: TimeInterval,
                         continuation: AsyncStream<LanScanEvent>.Continuation) async {
        let start = Date()
        let activity = AppActivityLog.shared.begin(.lanScan)
        defer { AppActivityLog.shared.end(activity) }
        continuation.yield(.started(subnet: subnet))

        // Store thread-safe per merge incrementale.
        let store = DeviceStore()
        let ouiLookup = OUILookup.shared
        let persistence = PersistenceManager.shared
        // Al primo scan non esiste uno storico: nessun dispositivo è "nuovo".
        let firstScan = persistence.isEmpty

        // Helper per emettere upsert dopo merge.
        @Sendable func emit(_ device: LanDevice) async {
            let merged = await store.upsert(device)
            // Arricchisci con persistenza se abbiamo il MAC
            var enriched = merged
            if let mac = merged.mac {
                if let pd = persistence.device(for: mac) {
                    enriched.customName = enriched.customName ?? pd.customName
                    enriched.firstSeen = enriched.firstSeen ?? pd.firstSeen
                    enriched.seenCount = max(enriched.seenCount, pd.seenCount)
                }
            }
            continuation.yield(.deviceUpsert(enriched))
        }

        // FASE 1 — ARP read immediato (~100ms): popoliamo subito con cache già nota
        continuation.yield(.phaseUpdate(.arp, completed: 0, total: 1))
        let arpEntries = await ARPTable.read(interfaceFilter: subnet.interface)
        let observations = ObservationLog()
        await observations.add(arpEntries)
        let arpByIP = Dictionary(arpEntries.map { ($0.ip, $0) }, uniquingKeysWith: { a, _ in a })

        for (ip, entry) in arpByIP {
            // Salta multicast/broadcast/network
            guard !ip.hasSuffix(".255"), !ip.hasPrefix("224."), !ip.hasPrefix("239."),
                  !ip.hasPrefix("255."), ip != subnet.networkAddress
            else { continue }
            let vendor = ouiLookup.vendor(for: entry.mac)
            let isMine = (ip == subnet.address)
            let isNew = persistence.recordSeen(mac: entry.mac, ip: ip, hostname: nil, vendor: vendor) && !firstScan
            await emit(LanDevice(
                ip: ip, mac: entry.mac, vendor: vendor,
                hostname: nil, services: [], isThisMac: isMine,
                isNew: isNew, isActive: isMine
            ))
        }
        continuation.yield(.phaseDone(.arp))

        // Aggiungiamo subito noi stessi anche se non in ARP cache
        if arpByIP[subnet.address] == nil {
            await emit(LanDevice(ip: subnet.address, isThisMac: true, isActive: true))
        }

        // FASE 2 — DNS reverse sugli IP già noti, Bonjour e ping sweep IN PARALLELO
        let initiallySeenIPs = await store.knownIPs()
        await withTaskGroup(of: Void.self) { group in

            // Task A: DNS reverse per gli IP già visti in ARP
            group.addTask {
                continuation.yield(.phaseUpdate(.dns, completed: 0, total: initiallySeenIPs.count))
                await Self.resolveAndEmit(ips: initiallySeenIPs, emit: emit)
            }

            // Task B: Bonjour browser
            group.addTask {
                continuation.yield(.phaseUpdate(.bonjour, completed: 0, total: 1))
                let bonjour = BonjourBrowser()
                let services = await bonjour.discover(duration: bonjourDuration)
                // Aggrega services per IPv4 risolto
                var servicesByIP: [String: [BonjourService]] = [:]
                for svc in services {
                    if let ip = svc.ipv4 {
                        servicesByIP[ip, default: []].append(svc)
                    }
                }
                for (ip, svcs) in servicesByIP {
                    await emit(LanDevice(ip: ip, services: svcs, isActive: true))
                }
                continuation.yield(.phaseDone(.bonjour))
            }

            // Task C: ping sweep, poi una sola lettura ARP e DNS sui soli IP nuovi
            group.addTask {
                let hosts = subnet.hostAddresses()
                continuation.yield(.phaseUpdate(.ping, completed: 0, total: hosts.count))
                let alive = await PingSweep(timeout: pingTimeout).sweep(addresses: hosts) { done, total in
                    continuation.yield(.phaseUpdate(.ping, completed: done, total: total))
                }

                // Lo sweep ha popolato la cache ARP anche per gli host che ignorano ICMP.
                let arp = await ARPTable.read(interfaceFilter: subnet.interface)
                await observations.add(arp)
                let macByIP = Dictionary(arp.map { ($0.ip, $0.mac) }, uniquingKeysWith: { a, _ in a })
                let hostSet = Set(hosts)
                let found = alive.union(macByIP.keys.filter { hostSet.contains($0) })
                let newIPs = found.subtracting(initiallySeenIPs).sorted {
                    (LocalSubnet.ipv4ToUInt32($0) ?? 0) < (LocalSubnet.ipv4ToUInt32($1) ?? 0)
                }

                for ip in newIPs {
                    let mac = macByIP[ip]
                    let vendor = mac.flatMap { ouiLookup.vendor(for: $0) }
                    let isNew = mac.map {
                        persistence.recordSeen(mac: $0, ip: ip, hostname: nil, vendor: vendor)
                    } ?? false
                    await emit(LanDevice(
                        ip: ip, mac: mac, vendor: vendor,
                        isThisMac: ip == subnet.address, isNew: isNew && !firstScan
                    ))
                }
                for ip in alive where hostSet.contains(ip) {
                    await emit(LanDevice(ip: ip, isActive: true))
                }
                continuation.yield(.phaseDone(.ping))

                await Self.resolveAndEmit(ips: newIPs, emit: emit)
                continuation.yield(.phaseDone(.dns))
            }

            // Task D: nodi del tailnet e subnet pubblicate dai subnet router / exit node
            group.addTask {
                await Self.scanTailscale(local: subnet, pingTimeout: pingTimeout,
                                         emit: emit, continuation: continuation)
            }

            // Task E: SSDP/UPnP per nome e modello di TV, router, NAS, console
            group.addTask {
                continuation.yield(.phaseUpdate(.upnp, completed: 0, total: 1))
                for d in await SSDPDiscovery.discover(duration: 3.0, interfaceAddress: subnet.address) {
                    let model = d.friendlyName
                        ?? [d.manufacturer, d.modelName].compactMap { $0 }.joined(separator: " ")
                    await emit(LanDevice(ip: d.ip, model: model.isEmpty ? nil : model, isActive: true))
                }
                continuation.yield(.phaseDone(.upnp))
            }

            await group.waitForAll()
        }

        // Finalizza
        let finalDevices = await store.snapshot()

        // Allarmi: confronta il MAC del gateway con quello memorizzato per questa rete.
        let seen = await observations.all()
        let gateway = await DiagnosticsService.defaultGateway()
        let gatewayMAC = gateway.flatMap { gw in seen.last { $0.ip == gw }?.mac }
        let previous = gateway.flatMap {
            GatewayMACStore.shared.mac(forGateway: $0, network: subnet.networkAddress)
        }
        continuation.yield(.alerts(NetworkAlertDetector.evaluate(
            observations: seen, devices: finalDevices,
            gatewayIP: gateway, previousGatewayMAC: previous)))
        if let gateway, let gatewayMAC {
            GatewayMACStore.shared.save(mac: gatewayMAC, forGateway: gateway, network: subnet.networkAddress)
        }
        let result = LanScanResult(
            subnet: subnet,
            devices: finalDevices,
            elapsed: Date().timeIntervalSince(start),
            timestamp: Date()
        )
        continuation.yield(.finished(result))
    }

    /// Emette i nodi Tailscale online e fa uno sweep ICMP delle subnet IPv4 pubblicate.
    /// Le subnet remote sono instradate (L3): niente ARP, MAC o Bonjour, solo IP e DNS reverse.
    private static func scanTailscale(local: LocalSubnet,
                                      pingTimeout: TimeInterval,
                                      emit: @escaping @Sendable (LanDevice) async -> Void,
                                      continuation: AsyncStream<LanScanEvent>.Continuation) async {
        continuation.yield(.phaseUpdate(.tailscale, completed: 0, total: 1))
        defer { continuation.yield(.phaseDone(.tailscale)) }
        guard let status = await TailscaleInspector.status() else { return }

        for peer in status.peers {
            guard let ip = peer.ipv4 else { continue }
            await emit(LanDevice(ip: ip, vendor: peer.os.isEmpty ? nil : peer.os,
                                 hostname: peer.dnsName ?? peer.hostName,
                                 isThisMac: peer.isSelf, network: LanDevice.tailnetLabel, isActive: true))
        }

        let subnets = status.routes.compactMap { route -> (LocalSubnet, String)? in
            guard let s = LocalSubnet(cidr: route.cidr, interface: "tailscale"),
                  s.prefixLength >= 22,          // al massimo ~1000 host attraverso la VPN
                  !s.overlaps(local)             // la LAN locale ha già la sua scansione
            else { return nil }
            return (s, "\(route.cidr) via \(route.via)")
        }
        let total = subnets.reduce(0) { $0 + $1.0.hostCount }
        var done = 0
        for (remote, label) in subnets {
            let hosts = remote.hostAddresses()
            // Latenza VPN più alta: timeout minimo 1.5 s.
            let offset = done
            let alive = await PingSweep(timeout: max(pingTimeout, 1.5)).sweep(addresses: hosts) { d, _ in
                continuation.yield(.phaseUpdate(.tailscale, completed: offset + d, total: total))
            }
            done += hosts.count
            let sorted = alive.sorted {
                (LocalSubnet.ipv4ToUInt32($0) ?? 0) < (LocalSubnet.ipv4ToUInt32($1) ?? 0)
            }
            for ip in sorted { await emit(LanDevice(ip: ip, network: label, isActive: true)) }
            await resolveAndEmit(ips: sorted, emit: emit)
        }
    }

    /// DNS reverse in parallelo; emette un upsert per ogni hostname trovato.
    private static func resolveAndEmit(ips: [String],
                                       emit: @escaping @Sendable (LanDevice) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for ip in ips {
                group.addTask {
                    if let host = await HostnameResolver.resolve(ip: ip) {
                        await emit(LanDevice(ip: ip, hostname: host))
                    }
                }
            }
        }
    }
}

// MARK: - Store thread-safe

private actor DeviceStore {
    private var devices: [String: LanDevice] = [:]

    func upsert(_ device: LanDevice) -> LanDevice {
        if let existing = devices[device.ip] {
            let merged = existing.merged(with: device)
            devices[device.ip] = merged
            return merged
        } else {
            devices[device.ip] = device
            return device
        }
    }

    func snapshot() -> [LanDevice] {
        Array(devices.values).sorted {
            (LocalSubnet.ipv4ToUInt32($0.ip) ?? 0) < (LocalSubnet.ipv4ToUInt32($1.ip) ?? 0)
        }
    }

    func knownIPs() -> [String] {
        Array(devices.keys)
    }
}

/// Coppie IP-MAC lette dalla cache ARP durante lo scan, in ordine di lettura.
private actor ObservationLog {
    private var items: [ARPObservation] = []
    func add(_ entries: [ARPEntry]) {
        items += entries.map { ARPObservation(ip: $0.ip, mac: $0.mac) }
    }
    func all() -> [ARPObservation] { items }
}

private actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}
