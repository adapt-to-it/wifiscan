import Foundation
import Testing
@testable import WifiScanCore

@Suite struct InterfaceStatsTests {
    static let defaultOnEn0 = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            192.168.1.1        UGScg                 en0
    127                127.0.0.1          UCS                   lo0
    """

    static let defaultOnUtunAfterLinkRoutes = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    127                127.0.0.1          UCS                   lo0
    192.168.1.5/32     link#4             UCS                   en0
    10.0.0.0/8         link#21            UCSI                utun6
    default            link#21            UCSIg               utun6
    """

    static let noDefault = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    127                127.0.0.1          UCS                   lo0
    192.168.1.0/24     link#4             UCS                   en0
    """

    @Test func parsesDefaultOnEn0() {
        #expect(InterfaceStats.parseDefaultInterface(netstat: Self.defaultOnEn0) == "en0")
    }

    @Test func parsesDefaultOnUtunAfterLinkRoutes() {
        #expect(InterfaceStats.parseDefaultInterface(netstat: Self.defaultOnUtunAfterLinkRoutes) == "utun6")
    }

    @Test func returnsNilWithoutDefaultRoute() {
        #expect(InterfaceStats.parseDefaultInterface(netstat: Self.noDefault) == nil)
    }

    @Test func sampleOnLoopbackDoesNotCrash() {
        let sample = InterfaceStats.sample(wifiInterface: "lo0")
        #expect(sample.t.timeIntervalSinceNow <= 1)
    }
}
