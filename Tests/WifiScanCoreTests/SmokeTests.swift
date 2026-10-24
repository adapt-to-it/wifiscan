import Foundation
import Testing
@testable import WifiScanCore

@Test func subnetFromCIDR() {
    let s = LocalSubnet(cidr: "192.168.1.0/24", interface: "x")
    #expect(s?.hostCount == 254)
}
