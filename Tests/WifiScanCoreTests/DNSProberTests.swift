import Foundation
import Testing
@testable import WifiScanCore

@Suite struct DNSProberTests {

    @Test func buildQueryEncodesHeaderNameAndTypeClass() {
        let packet = DNSProber.buildQuery(id: 0x1234, name: "a.bc")
        let expected: [UInt8] = [
            0x12, 0x34,             // id
            0x01, 0x00,             // flags: RD
            0x00, 0x01,             // QDCOUNT
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x61,             // "a"
            0x02, 0x62, 0x63,       // "bc"
            0x00,                   // terminatore del nome
            0x00, 0x01,             // QTYPE A
            0x00, 0x01,             // QCLASS IN
        ]
        #expect(packet == expected)
    }

    @Test func isResponseMatchesIdAndQRBit() {
        let response: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(DNSProber.isResponse(response, id: 0x1234) == true)
        #expect(DNSProber.isResponse(response, id: 0x1235) == false)

        let query: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(DNSProber.isResponse(query, id: 0x1234) == false)

        let short: [UInt8] = [0x12, 0x34, 0x81, 0x80]
        #expect(DNSProber.isResponse(short, id: 0x1234) == false)
    }

    @Test func measureInvalidAddressIsNil() async {
        let result = await DNSProber.measure(resolver: "999.1.1.1", timeout: 1)
        #expect(result == nil)
    }
}
