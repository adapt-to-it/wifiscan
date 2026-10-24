import Foundation
import Testing
@testable import WifiScanCore

@Suite struct SymptomsTests {
    private func set(_ features: [FeatureID: Graded], context: DiagnosisContext = DiagnosisContext()) -> FeatureSet {
        FeatureSet(features: features, context: context, monitorSeconds: 60)
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func notInvertsGradeAndKeepsConfidence() {
        let fs = set([.f1: Graded(0.2, confidence: 0.8)])
        let result = Symptoms.evaluate(.not(.feature(.f1)), features: fs)
        #expect(close(result.grade, 0.8))
        #expect(close(result.confidence, 0.8))
    }

    @Test func notOfMissingFeatureIsMissing() {
        let result = Symptoms.evaluate(.not(.feature(.f1)), features: set([:]))
        #expect(result == .missing)
    }

    @Test func andIgnoresMissingTerm() {
        let fs = set([.f1: Graded(0.6, confidence: 0.9)])
        let result = Symptoms.evaluate(.and(.feature(.f1), .feature(.f5)), features: fs)
        #expect(close(result.grade, 0.6))
        #expect(close(result.confidence, 0.9))
    }

    @Test func andWithAllTermsMissingIsMissing() {
        let result = Symptoms.evaluate(.and(.feature(.f1), .feature(.f5)), features: set([:]))
        #expect(result == .missing)
    }

    @Test func orPicksTermWithMaxGrade() {
        let fs = set([.f1: Graded(0.4, confidence: 0.5), .f5: Graded(0.7, confidence: 0.9)])
        let result = Symptoms.evaluate(.or(.feature(.f1), .feature(.f5)), features: fs)
        #expect(close(result.grade, 0.7))
        #expect(close(result.confidence, 0.9))
    }

    @Test func orIgnoresMissingTerm() {
        let fs = set([.f5: Graded(0.3, confidence: 0.6)])
        let result = Symptoms.evaluate(.or(.feature(.f1), .feature(.f5)), features: fs)
        #expect(close(result.grade, 0.3))
        #expect(close(result.confidence, 0.6))
    }

    @Test func groupIgnoresMissingTerms() {
        let fs = set([.f1: Graded(0.5, confidence: 0.4), .f6: Graded(0.2, confidence: 0.8)])
        let result = Symptoms.evaluate(.group([.feature(.f1), .feature(.f5), .feature(.f6)]), features: fs)
        #expect(close(result.grade, 0.5))
        #expect(close(result.confidence, 0.8))
    }

    @Test func groupWithAllTermsMissingIsMissing() {
        let result = Symptoms.evaluate(.group([.feature(.f1), .feature(.f5)]), features: set([:]))
        #expect(result == .missing)
    }

    @Test func scaleMultipliesConfidenceOnly() {
        let fs = set([.f1: Graded(0.6, confidence: 0.8)])
        let result = Symptoms.evaluate(.scale(.feature(.f1), 0.5), features: fs)
        #expect(close(result.grade, 0.6))
        #expect(close(result.confidence, 0.4))
    }

    @Test func s2IsMissingWithFullIcmpPenalty() {
        let context = DiagnosisContext(icmpPenalty: 1)
        let fs = set([.f20: Graded(0.9, confidence: 1)], context: context)
        #expect(Symptoms.all(fs)[.s2] == .missing)
    }

    @Test func s10IsMinOfDnsFeatures() {
        let fs = set([.f40: Graded(0.7, confidence: 0.9), .f41: Graded(0.4, confidence: 0.6)])
        let result = Symptoms.all(fs)[.s10]
        #expect(result != nil)
        #expect(close(result?.grade ?? -1, 0.4))
        #expect(close(result?.confidence ?? -1, 0.6))
    }
}
