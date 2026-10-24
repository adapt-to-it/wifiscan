import Foundation
import Testing
@testable import WifiScanCore

// Invarianti di DIAGNOSI.md 12.3 e metriche di regressione di 12.2 e 12.4, su scenari sintetici.
// Volumi pieni con DIAGNOSIS_FULL=1, altrimenti al 10 %. Minimo 10 per gruppo.
private let scale: Double = ProcessInfo.processInfo.environment["DIAGNOSIS_FULL"] == "1" ? 1 : 0.1

private let catalogFaults = Fault.allCases.filter { !$0.outOfCatalog }
private let outOfCatalogFaults = Fault.allCases.filter { $0.outOfCatalog }

/// Causa attesa per guasto del catalogo (mappa-guasti).
private let catalogCause: [Fault: CauseID] = [
    .weakSignal: .r1, .busyChannel: .r3, .slowRouter: .a1, .localBufferbloat: .g1,
    .lineBufferbloat: .w1, .lineLoss: .w2, .lineOutages: .w6, .slowDNS: .d1,
    .vpnExitNode: .v1, .awdlBursts: .p5,
]

private let sweepSeverities: [Double] = [0.3, 0.5, 0.7, 0.9]

/// PRNG deterministico locale (SplitMix64), uguale a quello del generatore, che è privato.
private struct TestRNG: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniforme in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
}

private struct Run {
    let scenario: Scenario
    let report: DiagnosisReport
}

/// Scenario violante, con i dati da stampare in caso di fallimento.
private struct Finding {
    let faults: [Fault]
    let severity: [Fault: Double]
    let outcome: String
    let top: String
    let note: String

    init(_ run: Run, note: String) {
        faults = run.scenario.faults
        severity = run.scenario.severity
        outcome = String(describing: run.report.outcome)
        top = run.report.posterior.marginals.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key.rawValue)=\(fmt($0.value))" }.joined(separator: ", ")
        self.note = note
    }
}

private func diagnose(_ scenario: Scenario) -> DiagnosisReport {
    let now = scenario.session.probes.map(\.t).max() ?? scenario.session.meta.start
    return DiagnosisEngine.diagnose(scenario.session, now: now)
}

/// Cause riportate dall'esito, come in DiagnosisEngine.diagnose.
private func reportedCauses(_ outcome: DiagnosisOutcome) -> Set<CauseID> {
    switch outcome {
    case .diagnosis(let causes): return Set(causes)
    case .probable(let cause, _): return [cause]
    case .ambiguous(let first, let second, _): return first.union(second)
    default: return []
    }
}

private func outcomeKind(_ outcome: DiagnosisOutcome) -> String {
    switch outcome {
    case .insufficientData: return "insufficientData"
    case .unknownAnomaly: return "unknownAnomaly"
    case .healthy: return "healthy"
    case .ambiguous: return "ambiguous"
    case .diagnosis: return "diagnosis"
    case .probable: return "probable"
    case .indeterminate: return "indeterminate"
    }
}

private func fmt(_ value: Double) -> String { String(format: "%.3f", value) }

/// Successo di regressione: causa mappata prima per marginale, oppure ambiguo con la causa
/// in first ∪ second e un test proposto che la separa.
private func isSuccess(_ outcome: DiagnosisOutcome, marginals: [CauseID: Double],
                       cause: CauseID, model: CausalModel) -> Bool {
    let top = marginals.max { $0.value < $1.value }?.key
    if top == cause { return true }
    if case .ambiguous(let first, let second, let proposed) = outcome {
        return first.union(second).contains(cause) && (model.tests[proposed]?.separates.contains(cause) ?? false)
    }
    return false
}

private func jitter(_ rng: inout TestRNG) -> Double { 1 + (rng.unit() * 2 - 1) * 0.05 }

/// Copia della sessione con rtt, rssi, txRate e ms DNS moltiplicati per 1 + u.
private func perturb(_ session: DiagnosisSession, rng: inout TestRNG) -> DiagnosisSession {
    var copy = session
    copy.probes = session.probes.map { sample in
        var noisy = sample
        if let rtt = noisy.rttMs { noisy.rttMs = rtt * jitter(&rng) }
        return noisy
    }
    copy.dns = session.dns.map { sample in
        var noisy = sample
        if let ms = noisy.ms { noisy.ms = ms * jitter(&rng) }
        return noisy
    }
    copy.link = session.link.map { sample in
        var noisy = sample
        noisy.rssi = Int((Double(sample.rssi) * jitter(&rng)).rounded())
        noisy.txRateMbps = sample.txRateMbps * jitter(&rng)
        return noisy
    }
    return copy
}

/// Stampa le violazioni solo se superano il numero ammesso.
private func printIfFailing(_ title: String, _ findings: [Finding], total: Int, allowed: Int) {
    guard findings.count > allowed else { return }
    print("\(title): violazioni \(findings.count) su \(total) (ammesse \(allowed))")
    for finding in findings.prefix(5) {
        let severity = finding.severity.map { "\($0.key.rawValue)=\(fmt($0.value))" }.sorted().joined(separator: ", ")
        print("  guasti [\(finding.faults.map(\.rawValue).joined(separator: ", "))] severity [\(severity)] "
              + "esito \(finding.outcome) marginali alti [\(finding.top)] nota: \(finding.note)")
    }
}

@Suite struct InvariantTests {
    private func volume(_ full: Int) -> Int { max(10, Int((Double(full) * scale).rounded())) }

    private func run(_ faults: [Fault], _ severity: [Fault: Double], seed: UInt64, ethernet: Bool = false) -> Run {
        var generator = ScenarioGenerator(seed: seed)
        let scenario = generator.make(faults: faults, severity: severity, ethernet: ethernet)
        return Run(scenario: scenario, report: diagnose(scenario))
    }

    private func singleRun(_ fault: Fault, seed: UInt64, ethernet: Bool = false) -> Run {
        var rng = TestRNG(state: seed)
        return run([fault], [fault: rng.range(0.3, 1)], seed: seed, ethernet: ethernet)
    }

    private func healthyRuns() -> [Run] {
        (0..<volume(2_000)).map { run([], [:], seed: 1_000 + UInt64($0)) }
    }

    private func singleRuns() -> [Run] {
        var runs: [Run] = []
        for (index, fault) in catalogFaults.enumerated() {
            for k in 0..<volume(200) {
                runs.append(singleRun(fault, seed: 2_000 + UInt64(index * 1_000 + k)))
            }
        }
        return runs
    }

    private func outOfCatalogRuns() -> [Run] {
        (0..<volume(2_000)).map { k in
            singleRun(outOfCatalogFaults[k % outOfCatalogFaults.count], seed: 4_000 + UInt64(k))
        }
    }

    /// Un seed per coppia (guasto, passo): i quattro passi di severity condividono il seed.
    private func sweepSeeds() -> [(fault: Fault, seed: UInt64)] {
        var pairs: [(fault: Fault, seed: UInt64)] = []
        for (index, fault) in catalogFaults.enumerated() {
            for k in 0..<volume(200) {
                pairs.append((fault: fault, seed: 5_000 + UInt64(index * 1_000 + k)))
            }
        }
        return pairs
    }

    private func monotonyRuns() -> [Run] {
        sweepSeeds().flatMap { pair in
            sweepSeverities.map { run([pair.fault], [pair.fault: $0], seed: pair.seed) }
        }
    }

    private func randomRuns() -> [Run] {
        var runs: [Run] = []
        for k in 0..<volume(300) {
            var generator = ScenarioGenerator(seed: 6_000 + UInt64(k))
            let scenario = generator.random()
            runs.append(Run(scenario: scenario, report: diagnose(scenario)))
        }
        return runs
    }

    private func ethernetRuns() -> [Run] {
        var runs: [Run] = (0..<volume(200)).map { run([], [:], seed: 9_000 + UInt64($0), ethernet: true) }
        for (index, fault) in catalogFaults.enumerated() {
            for k in 0..<volume(200) {
                runs.append(singleRun(fault, seed: 9_500 + UInt64(index * 1_000 + k), ethernet: true))
            }
        }
        return runs
    }

    /// Tutti gli scenari base degli altri test: sani, guasti singoli, fuori catalogo, monotonia, casuali.
    private func allRuns() -> [Run] {
        healthyRuns() + singleRuns() + outOfCatalogRuns() + monotonyRuns() + randomRuns()
    }

    // MARK: - Invarianti 12.3

    @Test func silenceOnHealthyNetwork() {
        let runs = healthyRuns()
        var findings: [Finding] = []
        for run in runs {
            let hot = run.report.posterior.marginals.filter { $0.key != .unknown && $0.value >= 0.4 }
            if let worst = hot.max(by: { $0.value < $1.value }) {
                findings.append(Finding(run, note: "\(worst.key.rawValue) P(h)=\(fmt(worst.value))"))
            }
        }
        printIfFailing("1 silenzio sulla rete sana", findings, total: runs.count, allowed: 0)
        #expect(findings.count == 0, "violazioni \(findings.count) su \(runs.count)")
    }

    @Test func monotonicityAlongSeverity() {
        var findings: [Finding] = []
        var comparisons = 0
        for pair in sweepSeeds() {
            guard let cause = catalogCause[pair.fault] else { continue }
            var previous: Run?
            for severity in sweepSeverities {
                let current = run([pair.fault], [pair.fault: severity], seed: pair.seed)
                if let before = previous {
                    comparisons += 1
                    let a = before.report.posterior.marginals[cause] ?? 0
                    let b = current.report.posterior.marginals[cause] ?? 0
                    if b < a - 0.02 {
                        findings.append(Finding(current, note: "\(cause.rawValue) cala da \(fmt(a)) a \(fmt(b))"))
                    }
                }
                previous = current
            }
        }
        printIfFailing("2 monotonia", findings, total: comparisons, allowed: 0)
        #expect(findings.count == 0, "violazioni \(findings.count) su \(comparisons) confronti")
    }

    @Test func noConfidentDiagnosisOutOfCatalog() {
        let runs = outOfCatalogRuns()
        var findings: [Finding] = []
        for run in runs {
            let hot = run.report.posterior.marginals.filter { $0.key != .unknown && $0.value >= 0.7 }
            if let worst = hot.max(by: { $0.value < $1.value }) {
                findings.append(Finding(run, note: "\(worst.key.rawValue) P(h)=\(fmt(worst.value))"))
            }
        }
        printIfFailing("3 fuori catalogo", findings, total: runs.count, allowed: 0)
        #expect(findings.count == 0, "violazioni \(findings.count) su \(runs.count)")
    }

    @Test func honestyBelowCoverage() {
        let runs = allRuns()
        var lowCoverage = 0
        var findings: [Finding] = []
        for run in runs where run.report.posterior.coverage < 0.5 {
            lowCoverage += 1
            if case .insufficientData = run.report.outcome { continue }
            findings.append(Finding(run, note: "copertura \(fmt(run.report.posterior.coverage))"))
        }
        printIfFailing("4 onestà", findings, total: runs.count, allowed: 0)
        #expect(findings.count == 0, "violazioni \(findings.count) su \(lowCoverage) con copertura sotto 0,5")
    }

    @Test func stabilityUnderNoise() {
        let total = volume(300)
        var findings: [Finding] = []
        for k in 0..<total {
            var generator = ScenarioGenerator(seed: 7_000 + UInt64(k))
            let scenario = generator.random()
            var rng = TestRNG(state: 8_000 + UInt64(k))
            var noisy = scenario
            noisy.session = perturb(scenario.session, rng: &rng)
            let base = diagnose(scenario)
            let other = diagnose(noisy)
            if outcomeKind(base.outcome) != outcomeKind(other.outcome)
                || reportedCauses(base.outcome) != reportedCauses(other.outcome) {
                findings.append(Finding(Run(scenario: scenario, report: base),
                                        note: "dopo il rumore: \(String(describing: other.outcome))"))
            }
        }
        let allowed = Int((0.03 * Double(total)).rounded(.down))
        printIfFailing("5 stabilità", findings, total: total, allowed: allowed)
        #expect(findings.count <= allowed, "violazioni \(findings.count) su \(total), ammesse \(allowed)")
    }

    @Test func reportedCausesAreExplained() {
        let model = Catalog.model
        let runs = allRuns()
        var checked = 0
        var findings: [Finding] = []
        for run in runs {
            for cause in reportedCauses(run.report.outcome) {
                checked += 1
                let q = model.causes.first { $0.id == cause }?.q ?? [:]
                let explained = run.report.symptoms.contains { $0.value.grade >= 0.5 && (q[$0.key] ?? 0) >= 0.5 }
                if !explained {
                    findings.append(Finding(run, note: "causa \(cause.rawValue) senza sintomo che la spiega"))
                }
            }
        }
        printIfFailing("6 spiegabilità", findings, total: checked, allowed: 0)
        #expect(findings.count == 0, "violazioni \(findings.count) su \(checked) cause riportate")
    }

    @Test func gatesAreRespected() {
        let ethernet = ethernetRuns()
        let forbiddenOnEthernet: Set<CauseID> = [.r1, .r3, .p5]
        var ethernetFindings: [Finding] = []
        for run in ethernet where !reportedCauses(run.report.outcome).isDisjoint(with: forbiddenOnEthernet) {
            ethernetFindings.append(Finding(run, note: "causa con gate falso riportata su ethernet"))
        }
        printIfFailing("7 gate ethernet", ethernetFindings, total: ethernet.count, allowed: 0)
        #expect(ethernetFindings.count == 0, "violazioni \(ethernetFindings.count) su \(ethernet.count)")

        let withoutVPN = allRuns().filter { !$0.scenario.faults.contains(.vpnExitNode) }
        var vpnFindings: [Finding] = []
        for run in withoutVPN where reportedCauses(run.report.outcome).contains(.v1) {
            vpnFindings.append(Finding(run, note: "v1 riportata senza exit node"))
        }
        printIfFailing("7 gate VPN", vpnFindings, total: withoutVPN.count, allowed: 0)
        #expect(vpnFindings.count == 0, "violazioni \(vpnFindings.count) su \(withoutVPN.count)")
    }

    // MARK: - Metriche di regressione 12.2 e 12.4

    @Test func regressionMetrics() {
        let model = Catalog.model

        let singles = singleRuns()
        var successes = 0
        var failures: [Finding] = []
        for run in singles {
            guard let fault = run.scenario.faults.first, let cause = catalogCause[fault] else { continue }
            if isSuccess(run.report.outcome, marginals: run.report.posterior.marginals, cause: cause, model: model) {
                successes += 1
            } else {
                failures.append(Finding(run, note: "causa attesa \(cause.rawValue)"))
            }
        }
        let allowedFailures = Int((0.1 * Double(singles.count)).rounded(.down))
        printIfFailing("regressione successo (soglia 90 %)", failures, total: singles.count, allowed: allowedFailures)
        #expect(failures.count <= allowedFailures, "successi \(successes) su \(singles.count), soglia 90 %")

        let healthy = healthyRuns()
        var alarms: [Finding] = []
        for run in healthy where !reportedCauses(run.report.outcome).isEmpty {
            alarms.append(Finding(run, note: "cause riportate su rete sana"))
        }
        let allowedAlarms = Int((0.02 * Double(healthy.count)).rounded(.down))
        printIfFailing("regressione falsi allarmi (soglia 2 %)", alarms, total: healthy.count, allowed: allowedAlarms)
        #expect(alarms.count <= allowedAlarms, "falsi allarmi \(alarms.count) su \(healthy.count), soglia 2 %")
    }
}
