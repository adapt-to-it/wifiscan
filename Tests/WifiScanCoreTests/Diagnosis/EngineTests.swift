import Foundation
import Testing
@testable import WifiScanCore

@Suite struct EngineTests {
    private func cause(_ id: CauseID, prior: Double, q: [SymptomID: Double],
                       gate: @escaping @Sendable (DiagnosisContext) -> Bool = { _ in true },
                       tests: [TestID] = [], exclusive: Bool = false) -> Cause {
        Cause(id: id, title: "\(id.rawValue)", prior: { _ in prior }, gate: gate, q: q, tests: tests,
              affirmative: "", cautious: "", exclusive: exclusive)
    }

    private func makeModel(_ causes: [Cause], exclusions: [(CauseID, CauseID)] = []) -> CausalModel {
        CausalModel(causes: causes, leak: [:], defaultLeak: 0.02, exclusions: exclusions, tests: [:])
    }

    private func observed(_ grades: [SymptomID: Double], confidence: Double = 1) -> [SymptomID: Graded] {
        grades.mapValues { Graded($0, confidence: confidence) }
    }

    @Test func explainingAwayFavorsSingleCause() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9, .s2: 0.9])
        let b = cause(.a1, prior: 0.1, q: [.s2: 0.9])
        let posterior = DiagnosisEngine.infer(symptoms: observed([.s1: 1, .s2: 1]),
                                              context: DiagnosisContext(), model: makeModel([a, b]))
        #expect(posterior.sets[0].causes == [.r1])
    }

    @Test func concurrentCausesWin() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9])
        let b = cause(.a1, prior: 0.1, q: [.s2: 0.9])
        let posterior = DiagnosisEngine.infer(symptoms: observed([.s1: 1, .s2: 1]),
                                              context: DiagnosisContext(), model: makeModel([a, b]))
        #expect(posterior.sets[0].causes == [.r1, .a1])
    }

    @Test func allZeroSymptomsAreHealthy() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9, .s2: 0.9])
        let b = cause(.a1, prior: 0.1, q: [.s2: 0.9])
        let symptoms = observed([.s1: 0, .s2: 0])
        let posterior = DiagnosisEngine.infer(symptoms: symptoms, context: DiagnosisContext(),
                                              model: makeModel([a, b]))
        let outcome = DiagnosisEngine.outcome(posterior, symptoms: symptoms, monitorSeconds: 120,
                                              model: makeModel([a, b]), userReportedProblem: false)
        #expect(outcome == .healthy(serviceSuspect: false))
    }

    @Test func missingDataIsInsufficient() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9])
        let b = cause(.a1, prior: 0.1, q: [.s2: 0.9])
        let model = makeModel([a, b])
        let symptoms: [SymptomID: Graded] = [.s1: .missing, .s2: .missing]
        let posterior = DiagnosisEngine.infer(symptoms: symptoms, context: DiagnosisContext(), model: model)
        let outcome = DiagnosisEngine.outcome(posterior, symptoms: symptoms, monitorSeconds: 120,
                                              model: model, userReportedProblem: false)
        #expect(outcome == .insufficientData(missing: [.s1, .s2]))
    }

    @Test func shortMonitorIsInsufficient() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9])
        let model = makeModel([a])
        let symptoms = observed([.s1: 1])
        let posterior = DiagnosisEngine.infer(symptoms: symptoms, context: DiagnosisContext(), model: model)
        let outcome = DiagnosisEngine.outcome(posterior, symptoms: symptoms, monitorSeconds: 30,
                                              model: model, userReportedProblem: false)
        #expect(outcome == .insufficientData(missing: []))
    }

    @Test func falseGateExcludesCause() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9], gate: { _ in false })
        let b = cause(.a1, prior: 0.1, q: [.s2: 0.9])
        let posterior = DiagnosisEngine.infer(symptoms: observed([.s1: 1, .s2: 0]),
                                              context: DiagnosisContext(), model: makeModel([a, b]))
        #expect(posterior.marginals[.r1] == nil)
        #expect(posterior.sets.allSatisfy { !$0.causes.contains(.r1) })
    }

    @Test func exclusionIsRespected() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9, .s2: 0.9])
        let b = cause(.a1, prior: 0.1, q: [.s1: 0.9, .s2: 0.9])
        let posterior = DiagnosisEngine.infer(symptoms: observed([.s1: 1, .s2: 1]),
                                              context: DiagnosisContext(),
                                              model: makeModel([a, b], exclusions: [(.r1, .a1)]))
        #expect(posterior.probability(of: [.r1, .a1]) == 0)
        #expect(posterior.sets.allSatisfy { !($0.causes.contains(.r1) && $0.causes.contains(.a1)) })
    }

    @Test func exclusiveCauseStandsAlone() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9])
        let u = cause(.unknown, prior: 0.02, q: [.s1: 0.3, .s2: 0.3], exclusive: true)
        let posterior = DiagnosisEngine.infer(symptoms: observed([.s1: 1, .s2: 1]),
                                              context: DiagnosisContext(), model: makeModel([a, u]))
        #expect(posterior.sets.allSatisfy { $0.causes.count <= 1 || !$0.causes.contains(.unknown) })
    }

    @Test func setProbabilitiesSumToOne() {
        let a = cause(.r1, prior: 0.1, q: [.s1: 0.9, .s2: 0.9])
        let b = cause(.a1, prior: 0.1, q: [.s2: 0.9])
        let posterior = DiagnosisEngine.infer(symptoms: observed([.s1: 1, .s2: 0.5]),
                                              context: DiagnosisContext(), model: makeModel([a, b]))
        let total = posterior.sets.reduce(0) { $0 + $1.probability }
        #expect(abs(total - 1) < 1e-9)
    }
}
