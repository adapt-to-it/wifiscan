import Foundation

/// Monitor della fase 0: raccoglie le misure in una DiagnosisSession.
public actor DiagnosisMonitor {
    private var session: DiagnosisSession?
    private var task: Task<Void, Never>?
    private var observer: LinkEventObserver?
    private var activity: NSObjectProtocol?
    private var lastInterface: InterfaceSample?
    /// Vero durante networkQuality: i campioni presi in questo periodo sono marcati underLoad.
    private var loadTestRunning = false
    private let icmp = ICMPProber()
    private let wifi = WiFiScanner()

    public init() {}

    public var isRunning: Bool { session != nil }

    /// Avvia una nuova sessione. Se il monitor è già attivo non fa nulla.
    public func start(locationAuthorized: Bool) {
        guard session == nil else { return }
        let meta = SessionMeta(
            start: Date(),
            macModel: Self.hardwareModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            wifiInterface: wifi.interfaceName(),
            locationAuthorized: locationAuthorized)
        session = DiagnosisSession(meta: meta)

        let observer = LinkEventObserver { [weak self] event in
            Task { await self?.appendEvent(event) }
        }
        self.observer = observer
        observer.start()

        // Durante la registrazione App Nap e lo stop per inattività fermerebbero il monitor.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Registrazione della sessione di diagnosi")
        task = Task { await self.collect() }
    }

    /// Ferma la raccolta e restituisce la sessione con `meta.end` impostato.
    public func stop() -> DiagnosisSession? {
        guard var result = session else { return nil }
        task?.cancel()
        observer?.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        result.meta.end = Date()
        result.activities = AppActivityLog.shared.intervals(since: result.meta.start)
        session = nil
        task = nil
        observer = nil
        lastInterface = nil
        loadTestRunning = false
        return result
    }

    /// Copia della sessione in corso.
    public func current() -> DiagnosisSession? { session }

    /// Esegue networkQuality marcando underLoad i campioni del periodo.
    public func runLoadTest() async -> LoadTestRecord? {
        guard session != nil else { return nil }
        loadTestRunning = true
        let start = Date()
        let outcome = try? await NetworkQualityRunner.run()
        let end = Date()
        loadTestRunning = false
        let record = LoadTestRecord(
            start: start,
            end: end,
            downloadMbps: outcome?.downloadMbps,
            uploadMbps: outcome?.uploadMbps,
            responsivenessRPM: outcome?.responsivenessRPM,
            baseRTTms: outcome?.baseRTTms,
            interfaceName: outcome?.interfaceName)
        session?.loadTests.append(record)
        return record
    }

    /// true se `t` cade in un intervallo o entro `margin` secondi dalla sua fine.
    static func isContaminated(_ t: Date, by intervals: [ActivityInterval], margin: TimeInterval = 0.5) -> Bool {
        intervals.contains { $0.start <= t && t <= $0.end.addingTimeInterval(margin) }
    }

    // MARK: - Ciclo di raccolta

    /// Un giro al secondo finché il task non viene cancellato da `stop`.
    /// Ogni 10 s: gateway, DNS. Ogni 60 s: vicini dalla cache dello scan.
    private func collect() async {
        var tick = 0
        var gateway: String?
        // Cadenza fissa: ogni giro parte a origin + tick secondi, qualunque sia la durata del lavoro.
        let clock = ContinuousClock()
        let origin = clock.now
        while !Task.isCancelled {
            let t = Date()
            if tick % 10 == 0 {
                gateway = await DiagnosticsService.defaultGateway()
            }

            let underLoad = loadTestRunning
            let intervals = AppActivityLog.shared.intervals(since: t.addingTimeInterval(-5))
            var targets: [(ProbeTarget, String)] = []
            for target in ProbeTarget.allCases {
                let address = target == .gateway ? gateway : target.fixedAddress
                if let address { targets.append((target, address)) }
            }
            let rtts = await icmp.probe(targets.map(\.1), timeout: 0.9)
            guard !Task.isCancelled else { return }
            for (target, address) in targets {
                let rtt: Double? = rtts[address] ?? nil
                session?.probes.append(ProbeSample(
                    t: t,
                    target: target,
                    rttMs: rtt,
                    contaminated: Self.isContaminated(t, by: intervals),
                    underLoad: underLoad))
            }

            sampleInterfaceAndLink()

            if tick % 10 == 0 {
                // Il DNS può attendere fino a 2 s: gira a parte per non ritardare i ping.
                let sessionID = session?.meta.id
                Task { [weak self] in
                    guard let self else { return }
                    let dns = await self.measureDNS(at: t, underLoad: underLoad)
                    await self.appendDNS(dns, sessionID: sessionID)
                }
            }
            if tick % 60 == 0 {
                session?.neighbors.append(neighborSnapshot(at: t))
            }

            tick += 1
            // Dopo uno stop del Mac (stop o sospensione) ContinuousClock è avanti di minuti: senza
            // riallineamento il ciclo recupererebbe tutti i giri persi uno dopo l'altro.
            let elapsed = Int((clock.now - origin) / .seconds(1))
            if elapsed > tick + 2 { tick = elapsed }
            try? await Task.sleep(until: origin + .seconds(tick), clock: clock)
        }
    }

    /// Scarta le misure arrivate dopo stop o appartenenti a una sessione precedente.
    private func appendDNS(_ samples: [DNSSample], sessionID: UUID?) {
        guard sessionID != nil, session?.meta.id == sessionID else { return }
        session?.dns.append(contentsOf: samples)
    }

    private func sampleInterfaceAndLink() {
        var txBytesPerSec: Double?
        if let name = session?.meta.wifiInterface {
            let sample = InterfaceStats.sample(wifiInterface: name)
            if let prev = lastInterface, sample.t > prev.t, sample.wifiTxBytes >= prev.wifiTxBytes {
                txBytesPerSec = Double(sample.wifiTxBytes - prev.wifiTxBytes) / sample.t.timeIntervalSince(prev.t)
            }
            lastInterface = sample
            session?.interfaces.append(sample)
        }
        if let snap = LinkMonitor.snapshot() {
            session?.link.append(LinkSample(
                t: snap.timestamp,
                bssid: snap.bssid,
                rssi: snap.rssi,
                noise: snap.noise,
                txRateMbps: snap.txRateMbps,
                phyMode: snap.phyMode,
                channel: snap.channel,
                band: snap.band?.rawValue,
                widthMHz: snap.widthMHz,
                txBytesPerSec: txBytesPerSec))
        }
    }

    private func measureDNS(at t: Date, underLoad: Bool) async -> [DNSSample] {
        let resolver = DNSProber.systemResolvers().first
        async let systemMs = resolver == nil ? nil : DNSProber.measure(resolver: resolver!, timeout: 2)
        async let cloudflareMs = DNSProber.measure(resolver: "1.1.1.1", timeout: 2)
        var samples: [DNSSample] = []
        if resolver != nil {
            samples.append(DNSSample(t: t, resolver: .system, ms: await systemMs, underLoad: underLoad))
        }
        samples.append(DNSSample(t: t, resolver: .cloudflare, ms: await cloudflareMs, underLoad: underLoad))
        return samples
    }

    private func neighborSnapshot(at t: Date) -> NeighborSnapshot {
        let records = wifi.cachedScan()
            .filter { !$0.bssid.isEmpty }
            .map { network in
                NeighborRecord(
                    bssid: network.bssid,
                    channel: network.channel,
                    band: network.band.rawValue,
                    widthMHz: network.width,
                    rssi: network.rssi,
                    noise: network.noise,
                    stationCount: network.beacon?.stationCount,
                    channelUtilization: network.beacon?.channelUtilization)
            }
        return NeighborSnapshot(t: t, networks: records)
    }

    private func appendEvent(_ event: LinkEvent) {
        session?.events.append(event)
    }

    /// Modello Mac da sysctl `hw.model`; stringa vuota se la lettura fallisce.
    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
