import Foundation
import Testing
@testable import WifiScanCore

@Suite struct ICMPProberTests {

    @Test func loopbackReplyHasRTTBelowTimeout() async throws {
        let prober = ICMPProber()
        let timeout: TimeInterval = 1.0
        let result = await prober.probe(["127.0.0.1"], timeout: timeout)
        let rtt = try #require(result["127.0.0.1"] ?? nil)
        #expect(rtt >= 0)
        #expect(rtt < timeout * 1000)
    }

    @Test func invalidAddressReturnsNil() async {
        let prober = ICMPProber()
        let result = await prober.probe(["x.y"], timeout: 0.2)
        #expect(result.keys.contains("x.y"))
        #expect((result["x.y"] ?? nil) == nil)
    }

    @Test func twoAddressesGiveTwoKeys() async {
        let prober = ICMPProber()
        let result = await prober.probe(["127.0.0.1", "127.0.0.2"], timeout: 0.3)
        #expect(result.count == 2)
    }
}
