import Foundation

/// Catalogo della fase 1, sezioni 8 e 11, come dati.
public enum Catalog {
    public static var model: CausalModel {
        CausalModel(causes: causes, leak: [.s4: 0.05, .s8: 0.05, .s13: 0.05], defaultLeak: 0.02,
                    exclusions: exclusions, tests: tests, maxConcurrent: 3)
    }

    public static var tests: [TestID: DiscriminatingTest] {
        let all: [DiscriminatingTest] = [
            DiscriminatingTest(id: .t1, kind: .user, title: "Cavo",
                               procedure: "Collegamento via Ethernet, poi ripetizione di monitor e M6",
                               separates: [.r1, .r3, .g1, .a1, .w1, .w2, .w6]),
            DiscriminatingTest(id: .t2, kind: .user, title: "Avvicinamento",
                               procedure: "30 s vicino al router, poi ritorno",
                               separates: [.r1, .r3, .a1]),
            DiscriminatingTest(id: .t3, kind: .user, title: "Senza exit node",
                               procedure: "Disattivazione dell'exit node, poi ripetizione",
                               separates: [.v1, .w1, .w2]),
            DiscriminatingTest(id: .t4, kind: .automatic, title: "Carico controllato",
                               procedure: "M6 con monitor in parallelo",
                               separates: [.g1, .w1]),
            DiscriminatingTest(id: .t5, kind: .automatic, title: "Traceroute",
                               procedure: "6 salti con TTL crescente",
                               separates: [.w2, .a1]),
            DiscriminatingTest(id: .t6, kind: .automatic, title: "DNS alternativo",
                               procedure: "Query parallele al resolver di sistema e a 1.1.1.1",
                               separates: [.d1, .w1, .w2]),
            DiscriminatingTest(id: .t7, kind: .automatic, title: "MTU",
                               procedure: "Ping con DF a dimensioni decrescenti",
                               separates: []),
            DiscriminatingTest(id: .t8, kind: .user, title: "Altra banda",
                               procedure: "Collegamento all'altra banda",
                               separates: [.r1, .r3, .a1]),
            DiscriminatingTest(id: .t9, kind: .automatic, title: "Ripetizione oraria",
                               procedure: "Misure ogni ora per 3 giorni",
                               separates: []),
            DiscriminatingTest(id: .t10, kind: .user, title: "Rete ferma",
                               procedure: "Pausa degli altri dispositivi",
                               separates: []),
            DiscriminatingTest(id: .t11, kind: .user, title: "Senza AWDL",
                               procedure: "AirDrop su \"Nessuno\", Handoff disattivato, 2 minuti di monitor",
                               separates: [.p5, .r3]),
            DiscriminatingTest(id: .t12, kind: .automatic, title: "Servizio specifico",
                               procedure: "Ping, DNS e connessione TCP verso l'host indicato dall'utente",
                               separates: []),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    /// Sostituisce i segnaposto `<chiave>` con i valori di `details` (DetailKey.rawValue); senza valore: "—".
    public static func render(_ template: String, details: [DetailKey: Double]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            out += rest[..<open]
            out += value(for: String(rest[rest.index(after: open)..<close]), details: details)
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    private static func value(for name: String, details: [DetailKey: Double]) -> String {
        guard let key = DetailKey(rawValue: name), let v = details[key], v.isFinite else { return "—" }
        return v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private static var exclusions: [(CauseID, CauseID)] {
        let others: [CauseID] = [.r1, .r3, .a1, .g1, .w1, .w2, .w6, .d1, .v1, .p5]
        return others.map { (CauseID.unknown, $0) } + [(.w6, .w1)]
    }

    private static var causes: [Cause] {
        [
            Cause(id: .r1, title: "Radio debole",
                  prior: { _ in 0.15 },
                  gate: { !$0.ethernet },
                  q: [.s1: 0.95, .s2: 0.5, .s3: 0.3, .s4: 0.4, .s5: 0.5, .s13: 0.2],
                  tests: [.t2, .t8],
                  affirmative: "Il segnale arriva debole rispetto al rumore. Avvicina il Mac al router o aggiungi un nodo mesh.",
                  cautious: "Il segnale sembra debole. Prova ad avvicinarti al router e ripeti la misura."),
            Cause(id: .r3, title: "Canale conteso",
                  prior: { _ in 0.15 },
                  gate: { !$0.ethernet },
                  q: [.s12: 0.9, .s4: 0.5, .s3: 0.3, .s5: 0.5, .s2: 0.15, .s13: 0.3],
                  tests: [.t8],
                  affirmative: "Il canale <channel> è occupato per il <channelUtilizationPct> % del tempo. Il canale <recommendedChannel> è il più libero: impostalo nel router.",
                  cautious: "Il canale <channel> sembra affollato. Prova il canale <recommendedChannel> nel router."),
            Cause(id: .a1, title: "Router lento",
                  prior: { _ in 0.08 },
                  q: [.s3: 0.7, .s4: 0.5, .s5: 0.3, .s2: 0.2],
                  tests: [.t1],
                  affirmative: "Il router risponde lento anche con un buon segnale. Riavvialo e verifica gli aggiornamenti del firmware.",
                  cautious: "Il router potrebbe essere lento. Riavvialo e ripeti la misura."),
            Cause(id: .g1, title: "Bufferbloat locale",
                  prior: { _ in 0.10 },
                  q: [.s5: 0.9, .s4: 0.2],
                  tests: [.t4, .t1],
                  affirmative: "La latenza verso il router sale quando la rete è carica. Attiva SQM o QoS nel router, oppure riduci il carico sul Wi-Fi.",
                  cautious: "La latenza locale sembra salire sotto carico. Ripeti il test con il Mac vicino al router."),
            Cause(id: .w1, title: "Bufferbloat della linea",
                  prior: { $0.vpnDefaultRoute ? 0.10 : 0.20 },
                  q: [.s6: 0.9, .s8: 0.1],
                  tests: [.t4, .t3],
                  affirmative: "La latenza verso internet esplode quando la linea è carica, mentre il collegamento locale resta stabile. Attiva SQM nel router con un limite al 90 % della banda.",
                  cautious: "La linea sembra soffrire sotto carico. Ripeti il test quando nessun altro usa la rete."),
            Cause(id: .w2, title: "Perdita sulla linea",
                  prior: { _ in 0.08 },
                  q: [.s7: 0.9, .s8: 0.3, .s10: 0.2],
                  tests: [.t5],
                  affirmative: "Il collegamento al router è pulito, ma la linea perde il <lossInternetPct> % dei pacchetti. Il guasto è del provider: apri una segnalazione.",
                  cautious: "La linea sembra perdere pacchetti. Ripeti la misura più tardi; se il dato resta, segnalalo al provider."),
            Cause(id: .w6, title: "Interruzioni di linea",
                  prior: { _ in 0.05 },
                  q: [.s9: 0.95, .s7: 0.1],
                  affirmative: "Internet si è interrotto <outagesPerHour> volte nell'ultima ora, mentre il router è rimasto raggiungibile. È un guasto di linea.",
                  cautious: "Ci sono state interruzioni verso internet. Lascia il monitor attivo per un'ora per confermarlo."),
            Cause(id: .d1, title: "DNS lento",
                  prior: { _ in 0.10 },
                  q: [.s10: 0.9],
                  tests: [.t6],
                  affirmative: "Il DNS impiega <dnsSystemMs> ms contro <dnsCloudflareMs> ms di 1.1.1.1. Imposta un DNS alternativo nel router.",
                  cautious: "Il DNS sembra più lento del normale. Prova un DNS alternativo."),
            Cause(id: .v1, title: "Exit node o VPN che limita la connessione",
                  prior: { _ in 0.6 },
                  gate: { $0.vpnDefaultRoute },
                  q: [.s8: 0.8, .s6: 0.4, .s10: 0.3, .s7: 0.5],
                  tests: [.t3],
                  affirmative: "Il traffico passa dall'exit node, che aggiunge <addedLatencyMs> ms. Disattivalo quando non serve, o scegli un exit node più vicino.",
                  cautious: "L'exit node potrebbe rallentare la connessione. Disattivalo e ripeti la misura."),
            Cause(id: .p5, title: "AWDL (AirDrop, Handoff, Sidecar)",
                  prior: { _ in 0.3 },
                  gate: { !$0.ethernet && $0.awdlActive },
                  q: [.s11: 0.9, .s4: 0.7, .s3: 0.1],
                  tests: [.t11],
                  affirmative: "AirDrop, Handoff o Sidecar portano periodicamente la radio su un altro canale e causano picchi di latenza. Disattivali durante chiamate e giochi.",
                  cautious: "I picchi di latenza regolari potrebbero dipendere da AirDrop o Handoff. Disattivali e ripeti la misura."),
            Cause(id: .unknown, title: "Causa ignota",
                  prior: { _ in 0.02 },
                  // S14 (deriva della latenza) non appartiene a nessuna causa nota: lo spiega solo U.
                  q: Dictionary(uniqueKeysWithValues: SymptomID.allCases.map { ($0, $0 == .s14 ? 0.8 : 0.3) }),
                  affirmative: "",
                  cautious: "",
                  exclusive: true),
        ]
    }
}
