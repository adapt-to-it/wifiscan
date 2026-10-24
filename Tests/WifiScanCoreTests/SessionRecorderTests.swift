import Foundation
import Testing
@testable import WifiScanCore

@Suite struct SessionRecorderTests {
    private let salt1 = Data(repeating: 0x01, count: 32)
    private let salt2 = Data(repeating: 0x02, count: 32)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Sessione con un campione per ogni tipo.
    private func sample() -> DiagnosisSession {
        let id = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!
        var s = DiagnosisSession(meta: SessionMeta(
            id: id, start: t0, end: t0.addingTimeInterval(600), macModel: "Mac15,6", osVersion: "15.0",
            wifiInterface: "en0", locationAuthorized: true, labels: ["R1"], note: "test"))
        s.probes = [ProbeSample(t: t0, target: .gateway, rttMs: 3.2, contaminated: false, underLoad: false)]
        s.dns = [DNSSample(t: t0, resolver: .system, ms: 12.5, underLoad: true)]
        s.link = [LinkSample(t: t0, bssid: "AA:BB:CC:DD:EE:FF", rssi: -55, noise: -92, txRateMbps: 866,
                             phyMode: "802.11ax", channel: 36, band: "5GHz", widthMHz: 80, txBytesPerSec: 1024)]
        s.interfaces = [InterfaceSample(t: t0, wifiTxBytes: 100, wifiRxBytes: 200, defaultRouteInterface: "en0",
                                        ethernetActive: false, awdlUp: true, awdlTxBytes: 5)]
        s.events = [LinkEvent(t: t0, kind: .bssidChanged, bssid: "AA:BB:CC:DD:EE:FF")]
        s.loadTests = [LoadTestRecord(start: t0, end: t0, downloadMbps: 100, uploadMbps: 20,
                                      responsivenessRPM: 900, baseRTTms: 15, interfaceName: "en0")]
        s.activities = [ActivityInterval(kind: .wifiScan, start: t0, end: t0)]
        s.neighbors = [NeighborSnapshot(t: t0, networks: [
            NeighborRecord(bssid: "AA:BB:CC:DD:EE:FF", channel: 6, band: "2.4GHz", widthMHz: 20,
                           rssi: -70, noise: -90, stationCount: nil, channelUtilization: 0.4),
        ])]
        return s
    }

    @Test func bssidCaseDoesNotChangePseudonym() {
        var upper = sample()
        upper.link[0].bssid = "AA:BB:CC:DD:EE:FF"
        var lower = sample()
        lower.link[0].bssid = "aa:bb:cc:dd:ee:ff"
        let a = SessionRecorder.anonymize(upper, salt: salt1).link[0].bssid
        let b = SessionRecorder.anonymize(lower, salt: salt1).link[0].bssid
        #expect(a == b)
        #expect(a?.count == 12)
        #expect(a != "AA:BB:CC:DD:EE:FF")
        #expect(a?.allSatisfy { $0.isHexDigit && !$0.isUppercase } == true)
    }

    @Test func differentSaltsGiveDifferentPseudonyms() {
        let a = SessionRecorder.anonymize(sample(), salt: salt1).link[0].bssid
        let b = SessionRecorder.anonymize(sample(), salt: salt2).link[0].bssid
        #expect(a != b)
    }

    @Test func nilBssidStaysNil() {
        var s = sample()
        s.link[0].bssid = nil
        s.events[0].bssid = nil
        let out = SessionRecorder.anonymize(s, salt: salt1)
        #expect(out.link[0].bssid == nil)
        #expect(out.events[0].bssid == nil)
    }

    @Test func allBssidSectionsUseTheSamePseudonym() {
        let out = SessionRecorder.anonymize(sample(), salt: salt1)
        let fromLink = out.link[0].bssid
        #expect(out.events[0].bssid == fromLink)
        #expect(out.neighbors[0].networks[0].bssid == fromLink)
        #expect(out.neighbors[0].networks[0].bssid.count == 12)
    }

    @Test func roundTripKeepsEverySection() throws {
        let s = sample()
        let data = try SessionRecorder.makeEncoder().encode(s)
        let back = try SessionRecorder.makeDecoder().decode(DiagnosisSession.self, from: data)
        #expect(back.schema == s.schema)
        #expect(back.meta == s.meta)
        #expect(back.probes == s.probes)
        #expect(back.dns == s.dns)
        #expect(back.link == s.link)
        #expect(back.interfaces == s.interfaces)
        #expect(back.events == s.events)
        #expect(back.loadTests == s.loadTests)
        #expect(back.activities == s.activities)
        #expect(back.neighbors == s.neighbors)
    }
}
