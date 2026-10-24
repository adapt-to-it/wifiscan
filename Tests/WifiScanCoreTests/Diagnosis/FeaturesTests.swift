import Foundation
import Testing
@testable import WifiScanCore

@Suite struct FeaturesTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func session() -> DiagnosisSession {
        DiagnosisSession(meta: SessionMeta(start: t0, macModel: "Mac15,6", osVersion: "15.0",
                                           wifiInterface: "en0", locationAuthorized: false))
    }

    @Test func rampUpIsLinearBetweenBounds() {
        #expect(FeatureExtractor.rampUp(0.2, 0.2, 0.5) == 0)
        #expect(FeatureExtractor.rampUp(0.5, 0.2, 0.5) == 1)
        #expect(abs(FeatureExtractor.rampUp(0.35, 0.2, 0.5) - 0.5) < 1e-12)
        #expect(FeatureExtractor.rampUp(-3, 0.2, 0.5) == 0)
        #expect(FeatureExtractor.rampUp(9, 0.2, 0.5) == 1)
    }

    @Test func rampDownIsComplementOfRampUp() {
        for x in [0.0, 0.3, 0.5, 0.9] {
            let expected = 1 - FeatureExtractor.rampUp(x, 0.2, 0.5)
            #expect(abs(FeatureExtractor.rampDown(x, 0.2, 0.5) - expected) < 1e-12)
        }
        #expect(FeatureExtractor.rampDown(15, 15, 28) == 1)
    }

    @Test func expectedEfficiencyFollowsSnrAndPhy() {
        // snrEff = 30 − 3·2 − 3 = 21 dB: MCS 5 su 13 (802.11be), 4,0 / 10,0
        let be = FeatureExtractor.expectedEfficiency(snr: 30, phy: "be", widthMHz: 80)
        #expect(be < 0.7)
        #expect(abs(be - 0.4) < 1e-9)
        // snrEff = 35 − 3·2 − 3 = 26 dB: MCS 7 su 9 (802.11ac), 5,0 / 6,67.
        // Il contratto indicava 1: non torna con la formula 4.4.2, vedi la nota nel rapporto.
        let ac = FeatureExtractor.expectedEfficiency(snr: 35, phy: "ac", widthMHz: 80)
        #expect(abs(ac - 5.0 / 6.67) < 1e-9)
    }

    @Test func maxRate2ssReadsTheTableAndRejectsMissingCombinations() {
        #expect(FeatureExtractor.maxRate2ss(phy: "802.11ac", widthMHz: 80) == 867)
        #expect(FeatureExtractor.maxRate2ss(phy: "ax", widthMHz: 160) == 2402)
        #expect(FeatureExtractor.maxRate2ss(phy: "802.11be", widthMHz: 320) == 5765)
        #expect(FeatureExtractor.maxRate2ss(phy: "802.11n", widthMHz: 80) == nil)
    }

    @Test func gatewayLossGradesWithTheShareOfTimeouts() {
        var s = session()
        // 12 timeout su 120 campioni = 10 %, sopra 5 %: grado 1.
        s.probes = (0..<120).map { i in
            ProbeSample(t: t0.addingTimeInterval(Double(i)), target: .gateway,
                        rttMs: i % 10 == 0 ? nil : 4, contaminated: false, underLoad: false)
        }
        let f20 = FeatureExtractor.extract(s, now: t0.addingTimeInterval(119))[.f20]
        #expect(!f20.isMissing)
        #expect(f20.grade == 1)
    }

    @Test func emptySessionGivesMissingFeatures() {
        let set = FeatureExtractor.extract(session(), now: t0.addingTimeInterval(300))
        for id in FeatureID.allCases {
            #expect(set[id].isMissing)
        }
        #expect(!set.context.vpnDefaultRoute)
        #expect(set.monitorSeconds == 0)
    }

    @Test func fixtureExitNodeSession() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/exit-node-1.json")
        let loaded = try SessionRecorder.load(url)
        let now = try #require(loaded.probes.map(\.t).max())
        let set = FeatureExtractor.extract(loaded, now: now)

        #expect(set.context.vpnDefaultRoute)
        #expect(set[.f24].grade > 0)
        #expect(abs(set[.f20].grade) < 0.05)
        #expect(!set[.f29x].isMissing)
    }
}
