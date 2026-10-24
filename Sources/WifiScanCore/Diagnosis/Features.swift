import Foundation

/// Feature e fatti di contesto della fase 1 (DIAGNOSI.md 3.2, 3.4, 4).
public enum FeatureExtractor {
    /// Finestre in secondi (4.2 e decisioni di fase 1).
    private static let pingWindow: Double = 120
    private static let linkWindow: Double = 60
    private static let scanWindow: Double = 60
    private static let outageWindow: Double = 3600
    private static let driftWindow: Double = 600
    private static let minOutageSeconds: Double = 120
    /// Campioni minimi sotto carico per F28 e F29x (4.2).
    private static let loadMinimum = 15
    /// Soglia di rilevamento del preambolo a 20 MHz (4.5).
    private static let rssiThreshold = -82
    /// 1 Mbit/s in byte al secondo (3.2.2).
    private static let trafficBytesPerSec: Double = 125_000

    /// Bit per simbolo per MCS 0...13, tabella 4.4.2.
    private static let mcsBits: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 4.5, 5.0, 6.0, 6.67, 7.5, 8.33, 9.0, 10.0]
    /// SNR minimo per MCS 0...13 (dB), tabella 4.4.2.
    private static let mcsSnrMin: [Double] = [5, 8, 11, 14, 17, 21, 23, 25, 29, 32, 35, 38, 41, 43]
    /// MCS più alto per PHY, sezione 4.4.2.
    private static let mcsTop: [String: Int] = ["n": 7, "ac": 9, "ax": 11, "be": 13]
    /// Rate massimo per 2 stream, tabella 4.4.1.
    private static let rates2ss: [String: [Int: Double]] = [
        "n": [20: 144, 40: 300],
        "ac": [20: 173, 40: 400, 80: 867, 160: 1733],
        "ax": [20: 287, 40: 574, 80: 1201, 160: 2402],
        "be": [20: 344, 40: 688, 80: 1441, 160: 2882, 320: 5765],
    ]

    /// Calcola feature, contesto e dettagli sulla finestra che termina a `now`.
    public static func extract(_ fullSession: DiagnosisSession, now: Date) -> FeatureSet {
        // Le misure di una rete precedente non descrivono quella attuale: si parte dall'ultimo cambio.
        let session = fullSession.trimmed(from: segmentStart(fullSession, now: now))
        let meta = session.meta
        let probes = session.probes.filter { $0.t <= now }.sorted { $0.t < $1.t }
        let dns = session.dns.filter { $0.t <= now }.sorted { $0.t < $1.t }
        let link = session.link.filter { $0.t <= now }.sorted { $0.t < $1.t }
        let interfaces = session.interfaces.filter { $0.t <= now }.sorted { $0.t < $1.t }
        let neighbors = session.neighbors.filter { $0.t <= now }.sorted { $0.t < $1.t }
        let internet: [ProbeTarget] = [.cloudflare, .google]
        let pingSince = now.addingTimeInterval(-pingWindow)
        let whole = Date.distantPast

        var features: [FeatureID: Graded] = [:]
        var details: [DetailKey: Double] = [:]
        func put(_ key: DetailKey, _ m: Measure?) {
            if let m { details[key] = m.value }
        }

        // Ping sulla finestra di 120 s. Bersagli internet: minimo tra i bersagli (3.2.4).
        // Perdita su tutti i campioni; latenza e jitter a riposo per F22, F25 e K6 (il nome dice "a riposo").
        let gwAll = ping(probes, .gateway, since: pingSince)
        let gwRest = ping(probes, .gateway, since: pingSince, underLoad: false)
        // Un'interruzione è già il sintomo S9: i suoi campioni non contano anche come perdita (S7).
        // Intervalli sulla finestra delle interruzioni: un'interruzione a cavallo dell'inizio
        // della finestra dei ping va riconosciuta per intero, non tagliata.
        let outageFrom = now.addingTimeInterval(-outageWindow)
        let outages = outageIntervals(
            probes.filter { $0.target != .gateway && !$0.contaminated && $0.t >= outageFrom },
            gateway: probes.filter { $0.target == .gateway && !$0.contaminated && $0.t >= outageFrom })
        let probesNoOutage = outages.isEmpty ? probes : probes.filter { p in
            p.target == .gateway || !outages.contains { $0.contains(p.t) }
        }
        let inetAll = internet.map { ping(probesNoOutage, $0, since: pingSince) }
        let inetRest = internet.map { ping(probes, $0, since: pingSince, underLoad: false) }

        let lossGw = combined([gwAll], minimum: 60, window: pingWindow, now: now) { $0.lossPct }
        let lossInet = combined(inetAll, minimum: 60, window: pingWindow, now: now) { $0.lossPct }
        let p50Gw = combined([gwRest], minimum: 60, window: pingWindow, now: now) { $0.p50 }
        let p50Inet = combined(inetRest, minimum: 60, window: pingWindow, now: now) { $0.p50 }
        let jitterGw = combined([gwAll], minimum: 60, window: pingWindow, now: now) { p in
            guard let p95 = p.p95, let p50 = p.p50 else { return nil }
            return p95 - p50
        }
        let lossDiff = difference(lossInet, lossGw)
        let latDiff = difference(p50Inet, p50Gw)

        features[.f20] = graded(lossGw) { rampUp($0, 0.5, 5) }
        features[.f22] = graded(p50Gw) { rampUp($0, 8, 30) }
        features[.f23] = graded(jitterGw) { rampUp($0, 10, 50) }
        // Su 120 campioni l'1–2 % è un solo pacchetto o due: il grado richiede anche un eccesso
        // di pacchetti persi oltre il gateway, che si avvia a 1 e diventa pieno a 3.
        let inetCount = inetAll.map(\.count).filter { $0 > 0 }.min() ?? 0
        features[.f24] = graded(lossDiff) { diff in
            rampUp(diff, 0.3, 2) * rampUp(diff / 100 * Double(inetCount), 1, 3)
        }
        features[.f25] = graded(latDiff) { rampUp($0, 40, 120) }
        put(.lossGatewayPct, lossGw)
        put(.lossInternetPct, lossInet)
        put(.p50GatewayMs, p50Gw)
        put(.p50InternetMs, p50Inet)
        put(.addedLatencyMs, latDiff)

        // K6: gateway che penalizza ICMP (3.2.6).
        let penalty = icmpPenalty(lostGw: gwAll.lost, countGw: gwAll.count, lossGw: lossGw?.value, lossInet: lossInet?.value,
                                  p50Gw: p50Gw?.value, p50Inet: p50Inet?.value)

        // Carico (F28, F29x): tutta la sessione fino a `now`. Il minimo di 15 conta i campioni sotto
        // carico di tutti i bersagli insieme: a 1 Hz un test di 12 s non darebbe mai 15 per bersaglio.
        let loadSamples = probes.filter { $0.underLoad && !$0.contaminated }.count
        let gwLoad = ping(probes, .gateway, since: whole, underLoad: true)
        let gwRestAll = ping(probes, .gateway, since: whole, underLoad: false)
        var gwDelta: Measure?
        // Sotto carico il 90° percentile: la coda si forma dopo qualche secondo di saturazione
        // e la mediana cadrebbe nella parte iniziale del test, ancora tranquilla.
        if loadSamples >= loadMinimum, let l = gwLoad.p90, let r = gwRestAll.p50 {
            gwDelta = Measure(value: l - r, confidence: 1)
        }
        features[.f28] = graded(gwDelta) { rampUp($0, 20, 100) }

        let inetLoadMin = internet.map { ping(probes, $0, since: whole, underLoad: true) }
            .compactMap { $0.p90 }
            .min()
        let inetRestMin = internet.map { ping(probes, $0, since: whole, underLoad: false) }
            .compactMap { $0.p50 }
            .min()
        var inetDelta: Measure?
        if loadSamples >= loadMinimum, let l = inetLoadMin, let r = inetRestMin {
            inetDelta = Measure(value: l - r, confidence: 1)
        }
        features[.f29x] = graded(difference(inetDelta, gwDelta)) { rampUp($0, 30, 150) }

        // F63: reattività di networkQuality nell'ultimo test sotto carico. RPM basso = coda lunga.
        // Conta solo con il router stabile sotto carico: se il router si gonfia, la coda è locale (S5).
        // Senza RPM la feature manca, così S6 non riceve un termine "router stabile" da solo.
        if let rpm = session.loadTests.filter({ $0.end <= now }).max(by: { $0.end < $1.end })?.responsivenessRPM {
            let routerStable = features[.f28].map { $0.isMissing ? 1 : 1 - $0.grade } ?? 1
            features[.f63] = Graded(min(rampDown(rpm, 150, 400), routerStable), confidence: 1)
        }

        // DNS (4.2): ultimi 10 campioni non sotto carico per resolver.
        let dnsSys = dnsP50(dns, .system)
        let dnsCf = dnsP50(dns, .cloudflare)
        features[.f40] = graded(dnsSys) { rampUp($0, 60, 250) }
        features[.f41] = graded(difference(dnsSys, dnsCf)) { rampUp($0, 30, 150) }
        put(.dnsSystemMs, dnsSys)
        put(.dnsCloudflareMs, dnsCf)

        // F1: SNR su 60 s, confidenza dai valori distinti consecutivi (minimo 10).
        let recentLink = link.filter { $0.t >= now.addingTimeInterval(-linkWindow) }
        var distinct = 0
        var previous: Int?
        for l in recentLink {
            let snr = l.rssi - l.noise
            if snr != previous {
                distinct += 1
                previous = snr
            }
        }
        let snrs = recentLink.map { Double($0.rssi - $0.noise) }
        if let snrP50 = quantile(snrs, 0.5), let last = recentLink.last?.t {
            let conf = min(1, Double(distinct) / 10) * freshness(last: last, window: linkWindow, now: now)
            features[.f1] = Graded(rampDown(snrP50, 15, 28), confidence: conf)
            details[.snrP50] = snrP50
        }

        // F5, F6: solo campioni con traffico reale, sullo stesso PHY e larghezza dell'ultimo.
        // Nessuno storico: nss = 2 e confidenza dimezzata (4.3).
        let traffic = link.filter { ($0.txBytesPerSec ?? 0) >= trafficBytesPerSec }
        if let ref = traffic.last {
            let width = ref.widthMHz ?? 20
            let group = traffic.filter { $0.phyMode == ref.phyMode && ($0.widthMHz ?? 20) == width }
            // rateRif = rateMax1ss × nss, con nss = 2: è maxRate2ss
            if let rateRif = maxRate2ss(phy: ref.phyMode, widthMHz: width),
               let rateP50 = quantile(group.map(\.txRateMbps), 0.5) {
                let eff = rateP50 / rateRif
                // Nessuno storico per nss: confidenza dimezzata (4.3).
                let conf = min(1, Double(group.count) / 10) * 0.5
                features[.f5] = Graded(eff, confidence: conf)
                if let snrP50 = quantile(group.map { Double($0.rssi - $0.noise) }, 0.5),
                   phyFamily(ref.phyMode) != nil {
                    let expected = expectedEfficiency(snr: snrP50, phy: ref.phyMode, widthMHz: width)
                    features[.f6] = Graded(rampUp(expected - eff, 0.15, 0.40), confidence: conf)
                }
            }
        }

        // F9: contesa del canale (4.5). AP corrente = record con il BSSID dell'ultimo campione.
        let currentLink = link.last
        let snapshot = neighbors.last
        var ap: NeighborRecord?
        if let snap = snapshot, let bssid = currentLink?.bssid {
            ap = snap.networks.first { $0.bssid == bssid }
        }
        let channelNow = ap?.channel ?? currentLink?.channel
        if let ch = channelNow {
            details[.channel] = Double(ch)
        }
        if let snap = snapshot, let ch = channelNow {
            let others = snap.networks.filter { $0.channel == ch && $0.bssid != ap?.bssid }
            let fresh = freshness(last: snap.t, window: scanWindow, now: now)
            if let u = ap?.channelUtilization {
                features[.f9] = Graded(rampUp(u, 0.45, 0.75), confidence: 1 * fresh)
                details[.channelUtilizationPct] = u * 100
            } else if let u = others.compactMap(\.channelUtilization).max() {
                features[.f9] = Graded(rampUp(u, 0.45, 0.75), confidence: 0.7 * fresh)
                details[.channelUtilizationPct] = u * 100
            } else {
                let busy = others.filter { $0.rssi >= rssiThreshold }.count
                features[.f9] = Graded(rampUp(Double(busy), 2, 6), confidence: 0.4 * fresh)
            }
        }
        if let snap = snapshot, let b = currentLink?.band,
           let rc = recommendedChannel(snap, band: b) {
            details[.recommendedChannel] = Double(rc)
        }

        // F62: deriva della latenza a riposo su 10 minuti. Per gateway e per bersaglio internet:
        // correlazione di rango tra tempo e RTT, e aumento tra il primo e l'ultimo quinto della serie.
        let driftSince = now.addingTimeInterval(-driftWindow)
        var drift: Graded?
        for target in [ProbeTarget.gateway, .cloudflare, .google] {
            let series = probes.filter {
                $0.target == target && !$0.contaminated && !$0.underLoad && $0.t >= driftSince && $0.t <= now
            }.compactMap { p in p.rttMs.map { (p.t.timeIntervalSince1970, $0) } }
            guard series.count >= 60 else { continue }
            let fifth = max(1, series.count / 5)
            let rise = (quantile(series.suffix(fifth).map(\.1), 0.5) ?? 0)
                - (quantile(series.prefix(fifth).map(\.1), 0.5) ?? 0)
            let rho = spearman(series.map(\.0), series.map(\.1))
            let g = Graded(min(rampUp(rho, 0.6, 0.8), rampUp(rise, 50, 100)),
                           confidence: min(1, Double(series.count) / 120))
            if drift == nil || g.grade > drift!.grade { drift = g }
        }
        if let drift { features[.f62] = drift }

        // F60: periodicità della serie RTT al gateway a riposo, lag 2–5 campioni (minimo 100).
        if gwRest.rtts.count > 5, let last = gwRest.last {
            let conf = min(1, Double(gwRest.rtts.count) / 100)
                * freshness(last: last, window: pingWindow, now: now)
            features[.f60] = Graded(rampUp(periodicPeak(gwRest.rtts), 0.2, 0.5), confidence: conf)
        }

        // F61: interruzioni di internet con gateway raggiungibile, per ora (fino a 60 min).
        let outageSince = now.addingTimeInterval(-outageWindow)
        let inetOut = probes.filter { $0.target != .gateway && !$0.contaminated && $0.t >= outageSince }
        let gwOut = probes.filter { $0.target == .gateway && !$0.contaminated && $0.t >= outageSince }
        if let first = inetOut.first, let lastT = inetOut.last?.t {
            let observed = min(outageWindow, now.timeIntervalSince(first.t))
            if observed >= minOutageSeconds {
                let runs = outageRuns(inetOut, gateway: gwOut)
                let perHour = Double(runs) * 3600 / observed
                // Interruzioni osservate sono una prova certa anche in pochi minuti;
                // la loro assenza pesa solo in proporzione alla durata osservata.
                let byDuration = max(0.3, min(1, observed / outageWindow))
                let conf = (runs > 0 ? 1 : byDuration)
                    * freshness(last: lastT, window: outageWindow, now: now)
                features[.f61] = Graded(rampUp(perHour, 0.5, 3), confidence: conf)
                details[.outagesPerHour] = perHour
            }
        }

        // Fatti di contesto (3.4).
        let lastIf = interfaces.last
        let route = lastIf?.defaultRouteInterface
        var ethernet = lastIf?.ethernetActive ?? false
        if let r = route, let wifi = meta.wifiInterface, r.hasPrefix("en"), r != wifi {
            ethernet = true
        }
        let context = DiagnosisContext(
            ethernet: ethernet,
            vpnDefaultRoute: route?.hasPrefix("utun") ?? false,
            awdlActive: awdlGrowing(interfaces, now: now),
            locationAuthorized: meta.locationAuthorized,
            backgroundTraffic: false,
            icmpPenalty: penalty,
            band: currentLink?.band)

        for id in FeatureID.allCases where features[id] == nil {
            features[id] = .missing
        }

        let lastSample = (probes.map(\.t) + dns.map(\.t) + link.map(\.t) + interfaces.map(\.t)).max()
        let monitor = lastSample.map { max(0, $0.timeIntervalSince(meta.start)) } ?? 0

        return FeatureSet(features: features, context: context, details: details, monitorSeconds: monitor)
    }

    /// Inizio del tratto di sessione sulla rete attuale (3.2): l'ultimo `linkUp` preceduto da un
    /// `linkDown`, oppure l'ultimo cambio dell'interfaccia di default (per esempio en0 → utun).
    /// Un roaming tra AP della stessa rete cambia solo il BSSID e non apre un nuovo tratto.
    static func segmentStart(_ session: DiagnosisSession, now: Date) -> Date {
        var start = Date.distantPast
        var down = false
        for e in session.events.sorted(by: { $0.t < $1.t }) where e.t <= now {
            switch e.kind {
            case .linkDown: down = true
            case .linkUp where down: start = e.t; down = false
            default: break
            }
        }
        var previous: String?
        for i in session.interfaces.sorted(by: { $0.t < $1.t }) where i.t <= now {
            guard let route = i.defaultRouteInterface else { continue }
            if let previous, previous != route { start = max(start, i.t) }
            previous = route
        }
        return start
    }

    public static func rampUp(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= a { return 0 }
        if x >= b { return 1 }
        return (x - a) / (b - a)
    }

    public static func rampDown(_ x: Double, _ a: Double, _ b: Double) -> Double {
        1 - rampUp(x, a, b)
    }

    /// Efficienza attesa per SNR, PHY e larghezza, tabella 4.4.2. `phy` come in LinkSample.phyMode.
    /// 0 se il PHY non è riconosciuto.
    public static func expectedEfficiency(snr: Double, phy: String, widthMHz: Int) -> Double {
        guard let family = phyFamily(phy), let top = mcsTop[family] else { return 0 }
        let snrEff = snr - 3 * log2(Double(widthMHz) / 20) - 3
        guard let mcs = (0...top).filter({ mcsSnrMin[$0] <= snrEff }).max() else { return 0 }
        return mcsBits[mcs] / mcsBits[top]
    }

    /// Rate massimo per 2 stream, tabella 4.4.1; nil se la combinazione non esiste.
    public static func maxRate2ss(phy: String, widthMHz: Int) -> Double? {
        guard let family = phyFamily(phy) else { return nil }
        return rates2ss[family]?[widthMHz]
    }

    /// Riconosce il PHY per sottostringa: "802.11ac", "11ac", "ac" sono uguali.
    private static func phyFamily(_ phy: String) -> String? {
        let p = phy.lowercased()
        return ["ax", "be", "ac", "n"].first { p.contains($0) }
    }

    /// Ping di un bersaglio: esclude i campioni contaminati e, se `underLoad` è dato, filtra per carico.
    private static func ping(_ probes: [ProbeSample], _ target: ProbeTarget, since: Date,
                             underLoad: Bool? = nil) -> Ping {
        var p = Ping()
        for s in probes where s.target == target && !s.contaminated && s.t >= since {
            if let u = underLoad, s.underLoad != u { continue }
            p.count += 1
            if let r = s.rttMs {
                p.rtts.append(r)
            } else {
                p.lost += 1
            }
            p.last = max(p.last ?? s.t, s.t)
        }
        return p
    }

    /// Valore minimo tra i bersagli che lo producono; confidenza minima tra quelli.
    private static func combined(_ pings: [Ping], minimum: Int, window: Double, now: Date,
                                 _ metric: (Ping) -> Double?) -> Measure? {
        var value: Double?
        var confidence = 1.0
        for p in pings {
            guard let v = metric(p) else { continue }
            value = min(value ?? v, v)
            confidence = min(confidence, confidenceOf(count: p.count, minimum: minimum,
                                                      last: p.last, window: window, now: now))
        }
        guard let value else { return nil }
        return Measure(value: value, confidence: confidence)
    }

    private static func confidenceOf(count: Int, minimum: Int, last: Date?, window: Double, now: Date) -> Double {
        min(1, Double(count) / Double(minimum)) * freshness(last: last, window: window, now: now)
    }

    /// 1 se l'ultimo campione è entro la finestra, poi lineare fino a 0 a 3 × finestra.
    private static func freshness(last: Date?, window: Double, now: Date) -> Double {
        guard let last else { return 0 }
        let age = now.timeIntervalSince(last)
        if age <= window { return 1 }
        return max(0, 1 - (age - window) / (2 * window))
    }

    private static func graded(_ m: Measure?, _ grade: (Double) -> Double) -> Graded {
        guard let m else { return .missing }
        return Graded(grade(m.value), confidence: m.confidence)
    }

    private static func difference(_ a: Measure?, _ b: Measure?) -> Measure? {
        guard let a, let b else { return nil }
        return Measure(value: a.value - b.value, confidence: min(a.confidence, b.confidence))
    }

    /// Ultimi 10 campioni non sotto carico per resolver. Confidenza sui risposte ricevute, su 10.
    private static func dnsP50(_ dns: [DNSSample], _ resolver: DNSResolverKind) -> Measure? {
        let recent = dns.filter { $0.resolver == resolver && !$0.underLoad }.suffix(10)
        let ms = recent.compactMap(\.ms)
        guard let p50 = quantile(ms, 0.5) else { return nil }
        return Measure(value: p50, confidence: min(1, Double(ms.count) / 10))
    }

    /// Massimo dell'autocorrelazione per lag 2–5 campioni (F60). Richiede più di 5 valori.
    private static func periodicPeak(_ xs: [Double]) -> Double {
        let n = xs.count
        let mean = xs.reduce(0, +) / Double(n)
        let d = xs.map { $0 - mean }
        let denom = d.reduce(0) { $0 + $1 * $1 }
        guard denom > 0 else { return 0 }
        var peak = 0.0
        for lag in 2...5 {
            var s = 0.0
            for i in 0..<(n - lag) {
                s += d[i] * d[i + lag]
            }
            peak = max(peak, s / denom)
        }
        return peak
    }

    /// Conta gli intervalli di almeno 10 s con entrambi i bersagli internet senza risposta
    /// e con il gateway che risponde nello stesso intervallo (F61).
    private static func outageRuns(_ internet: [ProbeSample], gateway: [ProbeSample]) -> Int {
        outageIntervals(internet, gateway: gateway).count
    }

    /// Intervalli delle interruzioni di F61, usati anche per escluderle dalla perdita di F24.
    private static func outageIntervals(_ internet: [ProbeSample], gateway: [ProbeSample]) -> [ClosedRange<Date>] {
        var intervals: [ClosedRange<Date>] = []
        var start: Date?
        var end: Date?
        func close() {
            if isOutage(start, end, gateway: gateway), let start, let end { intervals.append(start...end) }
            start = nil
            end = nil
        }
        for s in internet {
            if s.rttMs == nil {
                start = start ?? s.t
                end = s.t
            } else {
                close()
            }
        }
        close()
        return intervals
    }

    private static func isOutage(_ start: Date?, _ end: Date?, gateway: [ProbeSample]) -> Bool {
        guard let start, let end, end.timeIntervalSince(start) >= 10 else { return false }
        // Il gateway deve rispondere quasi sempre: con il Wi-Fi che perde metà dei pacchetti
        // una serie di risposte mancanti da internet non è un'interruzione della linea.
        let inside = gateway.filter { $0.t >= start && $0.t <= end }
        guard !inside.isEmpty else { return false }
        let answered = inside.filter { $0.rttMs != nil }.count
        return Double(answered) >= 0.8 * Double(inside.count)
    }

    /// K6, sezione 3.2.6: il grado più alto tra le due condizioni.
    private static func icmpPenalty(lostGw: Int, countGw: Int, lossGw: Double?, lossInet: Double?,
                                    p50Gw: Double?, p50Inet: Double?) -> Double {
        var grade = 0.0
        if let g = lossGw, let i = lossInet {
            // Conta l'eccesso di pacchetti persi al gateway rispetto a quanti se ne perderebbero
            // con la perdita verso internet. Su 120 campioni 1–2 pacchetti di scarto sono rumore,
            // anche quando la perdita totale è alta: la condizione si avvia a 3 e diventa piena a 6.
            let excess = Double(lostGw) - i / 100 * Double(countGw)
            grade = max(grade, rampUp(g - i, 0.5, 1) * rampUp(excess, 2, 6))
        }
        // Il ritardo del collegamento locale si somma a gateway e internet, quindi un rapporto
        // vicino a 1 è normale con il Wi-Fi lento. Solo un gateway più lento di internet è
        // fisicamente impossibile senza una penalità ICMP.
        if let g = p50Gw, let i = p50Inet, i > 0 {
            grade = max(grade, rampUp(g / i, 1.0, 1.3))
        }
        return grade
    }

    /// K3: il contatore awdl0 cresce negli ultimi 60 s.
    private static func awdlGrowing(_ interfaces: [InterfaceSample], now: Date) -> Bool {
        guard let last = interfaces.last else { return false }
        let since = now.addingTimeInterval(-60)
        guard let base = interfaces.last(where: { $0.t <= since }) ?? interfaces.first(where: { $0.t >= since }) else {
            return false
        }
        return last.awdlTxBytes > base.awdlTxBytes
    }

    /// Canale consigliato nella banda corrente (4.5): minor somma di utilizzo, poi meno vicini forti.
    private static func recommendedChannel(_ snap: NeighborSnapshot, band: String) -> Int? {
        let candidates: [Int]
        if band.contains("2.4") {
            candidates = [1, 6, 11]
        } else if band.contains("5") {
            candidates = [36, 52, 100, 149]
        } else {
            return nil
        }
        let scored = candidates.map { ch -> (channel: Int, load: Double, busy: Int) in
            let on = snap.networks.filter { $0.channel == ch }
            let load = on.reduce(0) { $0 + ($1.channelUtilization ?? 0) }
            return (ch, load, on.filter { $0.rssi >= rssiThreshold }.count)
        }
        return scored.min { ($0.load, $0.busy) < ($1.load, $1.busy) }?.channel
    }
}

/// Un valore con la sua confidenza (sezione 4.1).
private struct Measure {
    let value: Double
    let confidence: Double
}

/// Campioni di ping di un bersaglio nella finestra. `rtts` contiene solo le risposte, in ordine temporale.
private struct Ping {
    var count = 0
    var lost = 0
    var rtts: [Double] = []
    var last: Date?

    var lossPct: Double? { count == 0 ? nil : Double(lost) / Double(count) * 100 }
    var p50: Double? { quantile(rtts, 0.5) }
    var p90: Double? { quantile(rtts, 0.9) }
    var p95: Double? { quantile(rtts, 0.95) }
}

/// Correlazione di rango di Spearman, senza correzione per i pareggi.
private func spearman(_ x: [Double], _ y: [Double]) -> Double {
    func ranks(_ v: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: v.count)
        for (rank, i) in v.indices.sorted(by: { v[$0] < v[$1] }).enumerated() { r[i] = Double(rank) }
        return r
    }
    let rx = ranks(x), ry = ranks(y)
    let n = Double(x.count)
    let mean = (n - 1) / 2
    var num = 0.0, dx = 0.0, dy = 0.0
    for i in rx.indices {
        num += (rx[i] - mean) * (ry[i] - mean)
        dx += (rx[i] - mean) * (rx[i] - mean)
        dy += (ry[i] - mean) * (ry[i] - mean)
    }
    return dx > 0 && dy > 0 ? num / (dx * dy).squareRoot() : 0
}

/// Quantile con interpolazione lineare.
private func quantile(_ values: [Double], _ q: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let xs = values.sorted()
    let pos = q * Double(xs.count - 1)
    let lo = Int(pos.rounded(.down))
    let hi = Int(pos.rounded(.up))
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - Double(lo))
}
