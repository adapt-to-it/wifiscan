import Foundation
import Testing
@testable import WifiScanCore

@Suite struct ScenarioGeneratorTests {
    private func encode(_ session: DiagnosisSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(session)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    @Test func sameSeedGivesSameMeasures() throws {
        var first = ScenarioGenerator(seed: 42)
        var second = ScenarioGenerator(seed: 42)
        let faults: [Fault] = [.weakSignal, .awdlBursts]
        let severity: [Fault: Double] = [.weakSignal: 0.6, .awdlBursts: 0.4]
        let a = try encode(first.make(faults: faults, severity: severity).session)
        let b = try encode(second.make(faults: faults, severity: severity).session)
        #expect(a == b)
    }

    @Test func sameSeedGivesSameRandomScenario() throws {
        var first = ScenarioGenerator(seed: 7)
        var second = ScenarioGenerator(seed: 7)
        let a = first.random()
        let b = second.random()
        #expect(a.faults == b.faults)
        #expect(try encode(a.session) == encode(b.session))
    }

    @Test func threeHundredProbesPerTarget() {
        var generator = ScenarioGenerator(seed: 1)
        let session = generator.make(faults: [], severity: [:]).session
        for target in ProbeTarget.allCases {
            #expect(session.probes.filter { $0.target == target }.count == 300)
        }
        #expect(session.link.count == 300)
        #expect(session.interfaces.count == 300)
        #expect(session.dns.count == 60)
        #expect(session.neighbors.count == 5)
        #expect(session.loadTests.count == 1)
        #expect(session.meta.wifiInterface == "en0")
        #expect(session.meta.start == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func roundTripCodable() throws {
        var generator = ScenarioGenerator(seed: 3)
        let session = generator.make(faults: [.lineOutages, .slowDNS],
                                     severity: [.lineOutages: 0.8, .slowDNS: 0.5]).session
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(DiagnosisSession.self, from: data)
        #expect(decoded.meta == session.meta)
        #expect(decoded.probes == session.probes)
        #expect(decoded.dns == session.dns)
        #expect(decoded.link == session.link)
        #expect(decoded.interfaces == session.interfaces)
        #expect(decoded.loadTests == session.loadTests)
        #expect(decoded.activities == session.activities)
        #expect(decoded.neighbors == session.neighbors)
    }

    @Test func vpnExitNodeRoutesThroughUtun() {
        var generator = ScenarioGenerator(seed: 5)
        let session = generator.make(faults: [.vpnExitNode], severity: [.vpnExitNode: 0.7]).session
        #expect(!session.interfaces.isEmpty)
        #expect(session.interfaces.allSatisfy { $0.defaultRouteInterface?.hasPrefix("utun") == true })
    }

    @Test func lineBufferbloatRaisesInternetUnderLoad() {
        var generator = ScenarioGenerator(seed: 9)
        let session = generator.make(faults: [.lineBufferbloat], severity: [.lineBufferbloat: 0.5]).session
        let internet = session.probes.filter { $0.target != .gateway }
        let loaded = internet.filter { $0.underLoad }.compactMap { $0.rttMs }
        let rest = internet.filter { !$0.underLoad && !$0.contaminated }.compactMap { $0.rttMs }
        #expect(!loaded.isEmpty && !rest.isEmpty)
        #expect(median(loaded) > median(rest) + 50)
    }

    @Test func ethernetUsesEn7AndNoLinkSamples() {
        var generator = ScenarioGenerator(seed: 11)
        let session = generator.make(faults: [], severity: [:], ethernet: true).session
        #expect(session.link.isEmpty)
        #expect(!session.interfaces.isEmpty)
        #expect(session.interfaces.allSatisfy { $0.defaultRouteInterface == "en7" && $0.ethernetActive })
    }

    @Test func randomRespectsConstraints() {
        for seed in UInt64(1)...200 {
            var generator = ScenarioGenerator(seed: seed)
            let scenario = generator.random(outOfCatalogShare: 0.2)
            let outOfCatalog = scenario.faults.filter { $0.outOfCatalog }
            #expect(scenario.faults.count <= 3)
            #expect(outOfCatalog.isEmpty || scenario.faults.count == 1)
            #expect(!(scenario.faults.contains(.lineOutages) && scenario.faults.contains(.lineBufferbloat)))
            #expect(scenario.faults.allSatisfy { (0.3...1).contains(scenario.severity[$0] ?? -1) })
        }
    }
}
