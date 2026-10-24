import Foundation
import Testing
import CoreWLAN
@testable import WifiScanCore

@Suite struct LinkMonitorTests {
    @Test func qualityThresholds() {
        #expect(LinkMonitor.quality(snr: 40) == .excellent)
        #expect(LinkMonitor.quality(snr: 39) == .good)
        #expect(LinkMonitor.quality(snr: 25) == .good)
        #expect(LinkMonitor.quality(snr: 24) == .fair)
        #expect(LinkMonitor.quality(snr: 15) == .fair)
        #expect(LinkMonitor.quality(snr: 14) == .poor)
        #expect(LinkMonitor.quality(snr: 0) == .poor)
    }

    @Test func phyModeLabels() {
        #expect(LinkMonitor.phyModeLabel(.mode11a) == "802.11a")
        #expect(LinkMonitor.phyModeLabel(.mode11b) == "802.11b")
        #expect(LinkMonitor.phyModeLabel(.mode11g) == "802.11g")
        #expect(LinkMonitor.phyModeLabel(.mode11n) == "802.11n (Wi-Fi 4)")
        #expect(LinkMonitor.phyModeLabel(.mode11ac) == "802.11ac (Wi-Fi 5)")
        #expect(LinkMonitor.phyModeLabel(.mode11ax) == "802.11ax (Wi-Fi 6)")
        #expect(LinkMonitor.phyModeLabel(.modeNone) == "Sconosciuto")
    }
}
