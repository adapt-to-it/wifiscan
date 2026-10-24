import Testing
import Foundation
@testable import WifiScanCore

@Suite struct NetworkQualityTests {
    static let sample = Data("""
    {
      "dl_throughput": 250000000,
      "ul_throughput": 20000000,
      "responsiveness": 512,
      "base_rtt": 18.5,
      "interface_name": "en0",
      "error_code": 1003
    }
    """.utf8)

    private func make(rpm: Double) -> NetworkQualityResult {
        NetworkQualityResult(
            downloadMbps: 0,
            uploadMbps: 0,
            responsivenessRPM: rpm,
            baseRTTms: 0,
            interfaceName: nil,
            timestamp: Date()
        )
    }

    @Test func parseSampleJSON() throws {
        let r = try NetworkQualityRunner.parse(Self.sample)
        #expect(r.downloadMbps == 250)
        #expect(r.uploadMbps == 20)
        #expect(r.responsivenessRPM == 512)
        #expect(r.baseRTTms == 18.5)
        #expect(r.interfaceName == "en0")
    }

    @Test func parseWithoutDownloadThrows() {
        let json = Data(#"{"ul_throughput": 1000000, "responsiveness": 100}"#.utf8)
        #expect(throws: NetworkQualityError.self) {
            try NetworkQualityRunner.parse(json)
        }
    }

    @Test func labelAltaAtAndAboveEight() {
        #expect(make(rpm: 800).responsivenessLabel == "Alta")
        #expect(make(rpm: 1200).responsivenessLabel == "Alta")
    }

    @Test func labelMediaBetweenThreeHundredAndEight() {
        #expect(make(rpm: 799.9).responsivenessLabel == "Media")
        #expect(make(rpm: 300).responsivenessLabel == "Media")
    }

    @Test func labelBassaBelowThreeHundred() {
        #expect(make(rpm: 299.9).responsivenessLabel == "Bassa")
        #expect(make(rpm: 0).responsivenessLabel == "Bassa")
    }
}
