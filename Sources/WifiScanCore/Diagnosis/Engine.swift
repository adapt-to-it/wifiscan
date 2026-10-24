import Foundation

/// Inferenza noisy-OR su insiemi enumerati (sezione 6) ed esiti (sezione 7).
public enum DiagnosisEngine {
    public static func infer(symptoms: [SymptomID: Graded], context: DiagnosisContext, model: CausalModel) -> Posterior {
        let valuable = model.causes.filter { $0.gate(context) }
        let priors = valuable.map { $0.prior(context) }

        // Insiemi ammessi con il logaritmo del peso non normalizzato (sezione 6.2).
        var sets: [(causes: Set<CauseID>, logWeight: Double)] = []
        for indices in subsets(valuable.count, upTo: model.maxConcurrent) {
            let members = indices.map { valuable[$0] }
            let ids = Set(members.map { $0.id })
            if members.count > 1 && members.contains(where: { $0.exclusive }) { continue }
            if model.exclusions.contains(where: { ids.contains($0.0) && ids.contains($0.1) }) { continue }

            var logWeight = 0.0
            for i in valuable.indices {
                logWeight += indices.contains(i) ? log(priors[i]) : log(1 - priors[i])
            }
            for s in SymptomID.allCases {
                guard let graded = symptoms[s], graded.confidence > 0 else { continue }
                var none = 1 - model.leak(s)
                for cause in members { none *= 1 - (cause.q[s] ?? 0) }
                let p = 1 - none
                let base = graded.grade * p + (1 - graded.grade) * (1 - p)
                logWeight += graded.confidence * log(base)
            }
            sets.append((causes: ids, logWeight: logWeight))
        }

        // Normalizzazione dal massimo per evitare underflow.
        let maxLog = sets.map { $0.logWeight }.max() ?? -Double.infinity
        var weights: [Double] = []
        for entry in sets {
            weights.append(maxLog == -Double.infinity || entry.logWeight == -Double.infinity
                           ? 0 : exp(entry.logWeight - maxLog))
        }
        let total = weights.reduce(0, +)
        var entries: [(causes: Set<CauseID>, probability: Double)] = []
        for (i, entry) in sets.enumerated() {
            entries.append((causes: entry.causes, probability: total > 0 ? weights[i] / total : 0))
        }
        entries.sort { a, b in
            if a.probability != b.probability { return a.probability > b.probability }
            return causeKey(a.causes) < causeKey(b.causes)
        }

        var marginals: [CauseID: Double] = [:]
        for cause in valuable { marginals[cause.id] = 0 }
        for entry in entries {
            for id in entry.causes { marginals[id, default: 0] += entry.probability }
        }

        // Copertura, sezione 6.5. Il sintomo conta se q > 0 in una causa valutabile diversa da U.
        let relevant = valuable.filter { $0.id != .unknown }
        var imp: [SymptomID: Double] = [:]
        for cause in relevant {
            for (s, q) in cause.q where q > 0 { imp[s] = max(imp[s] ?? 0, q) }
        }
        var covered = 0.0
        var impTotal = 0.0
        for s in SymptomID.allCases {
            guard let v = imp[s] else { continue }
            covered += (symptoms[s]?.confidence ?? 0) * v
            impTotal += v
        }
        let coverage = impTotal > 0 ? covered / impTotal : 0

        var coverageByCause: [CauseID: Double] = [:]
        for cause in valuable {
            var num = 0.0
            var den = 0.0
            for s in SymptomID.allCases {
                guard let q = cause.q[s], q > 0 else { continue }
                num += (symptoms[s]?.confidence ?? 0) * q
                den += q
            }
            coverageByCause[cause.id] = den > 0 ? num / den : 0
        }

        return Posterior(sets: entries, marginals: marginals, coverage: coverage, coverageByCause: coverageByCause)
    }

    public static func outcome(_ posterior: Posterior, symptoms: [SymptomID: Graded], monitorSeconds: Double,
                               model: CausalModel, userReportedProblem: Bool) -> DiagnosisOutcome {
        // 1. Dati insufficienti.
        if posterior.coverage < 0.5 || monitorSeconds < 60 {
            let evidence = evidenceSymptoms(posterior, model: model)
            let missing = SymptomID.allCases.filter { s in
                evidence.contains(s) && (symptoms[s]?.isMissing ?? true)
            }
            return .insufficientData(missing: missing)
        }

        // 2. Anomalia non riconosciuta. I sintomi mancanti non contano.
        let pUnknown = posterior.marginals[.unknown] ?? 0
        if pUnknown >= 0.4 {
            let anomalous = SymptomID.allCases.filter { s in
                guard let graded = symptoms[s], !graded.isMissing else { return false }
                return graded.grade >= 0.5
            }
            return .unknownAnomaly(symptoms: anomalous)
        }

        // 3. Rete sana.
        if posterior.probability(of: []) >= 0.6 {
            return .healthy(serviceSuspect: userReportedProblem)
        }

        // Invariante 12.3.6: una causa si riporta solo se almeno un sintomo osservato la sostiene.
        // Senza questo controllo una causa con prior alto comparirebbe senza evidenze.
        func explained(_ id: CauseID) -> Bool {
            guard let cause = model.causes.first(where: { $0.id == id }) else { return false }
            return cause.q.contains { s, q in
                guard q >= 0.5, let graded = symptoms[s], !graded.isMissing else { return false }
                return graded.grade >= 0.5
            }
        }

        // 4. Ambigua: i due insiemi più probabili, separati da un test.
        let top = posterior.sets
        if top.count >= 2 {
            let first = top[0]
            let second = top[1]
            if first.probability < 0.6 && second.probability >= 0.4 * first.probability,
               first.causes.union(second.causes).allSatisfy(explained) {
                let difference = first.causes.symmetricDifference(second.causes)
                // Un test separa davvero le ipotesi se tocca ogni lato non vuoto
                // della differenza: un test che tocca un solo lato non le distingue.
                let sides = [first.causes.subtracting(second.causes),
                             second.causes.subtracting(first.causes)].filter { !$0.isEmpty }
                func touchesAllSides(_ t: DiscriminatingTest) -> Bool {
                    sides.allSatisfy { !t.separates.isDisjoint(with: $0) }
                }
                let candidates = model.tests.values
                    .filter { !$0.separates.isDisjoint(with: difference) }
                    .sorted { a, b in
                        let aBoth = touchesAllSides(a)
                        let bBoth = touchesAllSides(b)
                        if aBoth != bBoth { return aBoth }
                        let aAuto = a.kind == .automatic
                        let bAuto = b.kind == .automatic
                        if aAuto != bAuto { return aAuto }
                        return testOrder(a.id) < testOrder(b.id)
                    }
                if let test = candidates.first {
                    return .ambiguous(first: first.causes, second: second.causes, test: test.id)
                }
            }
        }

        let ranked = rankedCauses(posterior).filter { explained($0.id) }

        // 5. Diagnosi.
        let diagnosed = ranked
            .filter { $0.probability >= 0.7 && (posterior.coverageByCause[$0.id] ?? 0) >= 0.6 }
            .map { $0.id }
        if !diagnosed.isEmpty {
            return .diagnosis(causes: diagnosed)
        }

        // 6. Probabile.
        if let best = ranked.first, best.probability >= 0.4 {
            let cause = model.causes.first(where: { $0.id == best.id })
            return .probable(cause: best.id, test: cause?.tests.first)
        }

        // 7. Indeterminato: test delle tre cause più probabili, senza duplicati.
        var tests: [TestID] = []
        for entry in ranked.prefix(3) {
            let causeTests = model.causes.first(where: { $0.id == entry.id })?.tests ?? []
            for test in causeTests where !tests.contains(test) { tests.append(test) }
        }
        return .indeterminate(tests: tests)
    }

    /// Pipeline completa: feature, sintomi, inferenza, esito, testi delle azioni.
    public static func diagnose(_ session: DiagnosisSession, now: Date, userReportedProblem: Bool = false,
                                model: CausalModel = Catalog.model) -> DiagnosisReport {
        let features = FeatureExtractor.extract(session, now: now)
        let symptoms = Symptoms.all(features)
        let posterior = infer(symptoms: symptoms, context: features.context, model: model)
        let result = outcome(posterior, symptoms: symptoms, monitorSeconds: features.monitorSeconds,
                             model: model, userReportedProblem: userReportedProblem)

        var reported: [CauseID] = []
        var affirmative = false
        switch result {
        case .diagnosis(let causes):
            reported = causes
            affirmative = true
        case .probable(let cause, _):
            reported = [cause]
        case .ambiguous(let first, let second, _):
            reported = Array(first.union(second))
        default:
            break
        }

        var actions: [CauseID: String] = [:]
        for id in reported {
            guard let cause = model.causes.first(where: { $0.id == id }) else { continue }
            let template = affirmative ? cause.affirmative : cause.cautious
            guard !template.isEmpty else { continue }
            actions[id] = Catalog.render(template, details: features.details)
        }

        return DiagnosisReport(outcome: result, posterior: posterior, symptoms: symptoms,
                               features: features, actions: actions)
    }

    // MARK: - Supporto

    /// Insiemi di indici di dimensione fino a `limit`, in ordine di generazione.
    private static func subsets(_ count: Int, upTo limit: Int) -> [[Int]] {
        var result: [[Int]] = []
        func extend(_ current: [Int], from start: Int) {
            result.append(current)
            guard current.count < limit else { return }
            for i in start..<count { extend(current + [i], from: i + 1) }
        }
        extend([], from: 0)
        return result
    }

    private static func causeKey(_ causes: Set<CauseID>) -> String {
        causes.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    private static func testOrder(_ id: TestID) -> Int {
        TestID.allCases.firstIndex(of: id) ?? Int.max
    }

    /// Cause valutabili diverse da U, per probabilità decrescente.
    private static func rankedCauses(_ posterior: Posterior) -> [(id: CauseID, probability: Double)] {
        posterior.marginals
            .filter { $0.key != .unknown }
            .map { (id: $0.key, probability: $0.value) }
            .sorted { a, b in
                if a.probability != b.probability { return a.probability > b.probability }
                return a.id.rawValue < b.id.rawValue
            }
    }

    /// Sintomi con q > 0 in una causa valutabile diversa da U.
    private static func evidenceSymptoms(_ posterior: Posterior, model: CausalModel) -> Set<SymptomID> {
        var result = Set<SymptomID>()
        for cause in model.causes where cause.id != .unknown && posterior.marginals[cause.id] != nil {
            for (s, q) in cause.q where q > 0 { result.insert(s) }
        }
        return result
    }
}
