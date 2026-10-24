import Foundation

// Tipi condivisi del motore di diagnosi, fase 1 (DIAGNOSI.md, sezioni 4–8).
// Pipeline: DiagnosisSession → FeatureSet → sintomi → Posterior → DiagnosisOutcome.

/// Grado tra 0 e 1 con la sua confidenza (sezione 4.1). Confidenza sotto 0,3 = mancante.
public struct Graded: Sendable, Hashable, Codable {
    public var grade: Double
    public var confidence: Double

    public init(_ grade: Double, confidence: Double) {
        self.grade = min(1, max(0, grade)); self.confidence = min(1, max(0, confidence))
    }

    public static let missing = Graded(0, confidence: 0)
    public static let minimumConfidence = 0.3
    public var isMissing: Bool { confidence < Graded.minimumConfidence }
}

/// Feature della fase 1, sezione 4.2.
public enum FeatureID: String, Sendable, Hashable, Codable, CaseIterable {
    case f1, f5, f6, f9, f20, f22, f23, f24, f25, f28, f29x, f40, f41, f60, f61, f62, f63
}

/// Fatti di contesto K1–K7, sezione 3.4.
public struct DiagnosisContext: Sendable, Hashable, Codable {
    /// K1: route predefinita su un'interfaccia cablata.
    public var ethernet: Bool
    /// K2: route predefinita su `utun` (exit node o altra VPN).
    public var vpnDefaultRoute: Bool
    /// K3: `awdl0` con byte trasmessi negli ultimi 60 s. Il solo flag di interfaccia attiva non basta.
    public var awdlActive: Bool
    /// K4
    public var locationAuthorized: Bool
    /// K5: traffico del Mac in background durante il test sotto carico.
    public var backgroundTraffic: Bool
    /// K6: grado tra 0 e 1 del gateway che penalizza ICMP.
    public var icmpPenalty: Double
    /// K7: "2.4 GHz", "5 GHz", "6 GHz" o nil.
    public var band: String?

    public init(ethernet: Bool = false, vpnDefaultRoute: Bool = false, awdlActive: Bool = false,
                locationAuthorized: Bool = false, backgroundTraffic: Bool = false,
                icmpPenalty: Double = 0, band: String? = nil) {
        self.ethernet = ethernet; self.vpnDefaultRoute = vpnDefaultRoute; self.awdlActive = awdlActive
        self.locationAuthorized = locationAuthorized; self.backgroundTraffic = backgroundTraffic
        self.icmpPenalty = icmpPenalty; self.band = band
    }
}

/// Valori grezzi riassunti, usati nei testi delle azioni ("<x> %", "<t> ms").
public enum DetailKey: String, Sendable, Hashable, Codable {
    case snrP50, lossGatewayPct, lossInternetPct, p50GatewayMs, p50InternetMs
    case addedLatencyMs        // p50_inet − p50_gw a riposo
    case dnsSystemMs, dnsCloudflareMs
    case channel, channelUtilizationPct, recommendedChannel
    case outagesPerHour
}

public struct FeatureSet: Sendable, Codable {
    public var features: [FeatureID: Graded]
    public var context: DiagnosisContext
    public var details: [DetailKey: Double]
    /// Secondi di monitor coperti dalla sessione.
    public var monitorSeconds: Double

    public init(features: [FeatureID: Graded], context: DiagnosisContext,
                details: [DetailKey: Double] = [:], monitorSeconds: Double) {
        self.features = features; self.context = context; self.details = details
        self.monitorSeconds = monitorSeconds
    }

    public subscript(_ id: FeatureID) -> Graded { features[id] ?? .missing }
}

/// Vocabolario chiuso dei sintomi, sezione 5.2.
public enum SymptomID: String, Sendable, Hashable, Codable, CaseIterable {
    case s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14
}

/// Algebra delle espressioni, sezione 5.1. Nessun'altra forma è ammessa.
public indirect enum Expr: Sendable, Hashable {
    case feature(FeatureID)
    case not(Expr)
    case and(Expr, Expr)
    case or(Expr, Expr)
    case group([Expr])
    /// Moltiplica la confidenza per `k`, il grado resta invariato.
    case scale(Expr, Double)
}

public enum CauseID: String, Sendable, Hashable, Codable, CaseIterable {
    case r1, r3, a1, g1, w1, w2, w6, d1, v1, p5
    /// Causa ignota U, sezione 6.4.
    case unknown
}

public enum TestID: String, Sendable, Hashable, Codable, CaseIterable {
    case t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12
}

public enum TestKind: String, Sendable, Codable { case automatic, user }

public struct DiscriminatingTest: Sendable {
    public var id: TestID
    public var kind: TestKind
    public var title: String
    public var procedure: String
    /// Cause che il test separa. Due insiemi sono separabili se il test tocca una causa presente in uno solo.
    public var separates: Set<CauseID>

    public init(id: TestID, kind: TestKind, title: String, procedure: String, separates: Set<CauseID>) {
        self.id = id; self.kind = kind; self.title = title; self.procedure = procedure; self.separates = separates
    }
}

/// Voce del catalogo, sezione 8.
public struct Cause: Sendable {
    public var id: CauseID
    public var title: String
    /// Prior in funzione del contesto (per esempio W1: 0,20, ma 0,10 con K2).
    public var prior: @Sendable (DiagnosisContext) -> Double
    /// Se falso, la causa non è valutabile e non entra negli insiemi.
    public var gate: @Sendable (DiagnosisContext) -> Bool
    /// q_h,s; i sintomi assenti valgono 0.
    public var q: [SymptomID: Double]
    public var tests: [TestID]
    /// Testo per l'esito Diagnosi. Segnaposto `<chiave>` = DetailKey.rawValue.
    public var affirmative: String
    /// Testo per l'esito Probabile.
    public var cautious: String
    /// Se true, la causa non coesiste con nessun'altra (causa ignota).
    public var exclusive: Bool

    public init(id: CauseID, title: String,
                prior: @escaping @Sendable (DiagnosisContext) -> Double,
                gate: @escaping @Sendable (DiagnosisContext) -> Bool = { _ in true },
                q: [SymptomID: Double], tests: [TestID] = [],
                affirmative: String, cautious: String, exclusive: Bool = false) {
        self.id = id; self.title = title; self.prior = prior; self.gate = gate; self.q = q
        self.tests = tests; self.affirmative = affirmative; self.cautious = cautious; self.exclusive = exclusive
    }
}

/// Modello completo passato al motore: cause, perdite λ e matrice di esclusione.
public struct CausalModel: Sendable {
    public var causes: [Cause]
    public var leak: [SymptomID: Double]
    public var defaultLeak: Double
    public var exclusions: [(CauseID, CauseID)]
    public var tests: [TestID: DiscriminatingTest]
    public var maxConcurrent: Int

    public init(causes: [Cause], leak: [SymptomID: Double], defaultLeak: Double,
                exclusions: [(CauseID, CauseID)], tests: [TestID: DiscriminatingTest], maxConcurrent: Int = 3) {
        self.causes = causes; self.leak = leak; self.defaultLeak = defaultLeak
        self.exclusions = exclusions; self.tests = tests; self.maxConcurrent = maxConcurrent
    }

    public func leak(_ s: SymptomID) -> Double { leak[s] ?? defaultLeak }
}

/// Risultato dell'inferenza, sezione 6.
public struct Posterior: Sendable {
    /// Insiemi ammessi con la loro probabilità a posteriori normalizzata, in ordine decrescente.
    public var sets: [(causes: Set<CauseID>, probability: Double)]
    /// P(h) per ogni causa valutabile.
    public var marginals: [CauseID: Double]
    /// Copertura globale, sezione 6.5.
    public var coverage: Double
    public var coverageByCause: [CauseID: Double]

    public init(sets: [(causes: Set<CauseID>, probability: Double)], marginals: [CauseID: Double],
                coverage: Double, coverageByCause: [CauseID: Double]) {
        self.sets = sets; self.marginals = marginals; self.coverage = coverage; self.coverageByCause = coverageByCause
    }

    public func probability(of set: Set<CauseID>) -> Double {
        sets.first { $0.causes == set }?.probability ?? 0
    }
}

/// Esiti, sezione 7, in ordine di precedenza.
public enum DiagnosisOutcome: Sendable, Equatable {
    case insufficientData(missing: [SymptomID])
    case unknownAnomaly(symptoms: [SymptomID])
    case healthy(serviceSuspect: Bool)
    case ambiguous(first: Set<CauseID>, second: Set<CauseID>, test: TestID)
    case diagnosis(causes: [CauseID])
    case probable(cause: CauseID, test: TestID?)
    case indeterminate(tests: [TestID])
}

/// Prodotto finale per l'interfaccia.
public struct DiagnosisReport: Sendable {
    public var outcome: DiagnosisOutcome
    public var posterior: Posterior
    public var symptoms: [SymptomID: Graded]
    public var features: FeatureSet
    /// Testo dell'azione per ogni causa riportata, segnaposto già sostituiti.
    public var actions: [CauseID: String]

    public init(outcome: DiagnosisOutcome, posterior: Posterior, symptoms: [SymptomID: Graded],
                features: FeatureSet, actions: [CauseID: String]) {
        self.outcome = outcome; self.posterior = posterior; self.symptoms = symptoms
        self.features = features; self.actions = actions
    }
}
