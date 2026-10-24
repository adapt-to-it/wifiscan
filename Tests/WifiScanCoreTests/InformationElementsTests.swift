import Foundation
import Testing
@testable import WifiScanCore

@Suite struct InformationElementsTests {

    /// Un IE: id, lunghezza, payload.
    private func tlv(_ id: UInt8, _ body: [UInt8]) -> [UInt8] {
        [id, UInt8(body.count)] + body
    }

    private func parse(_ bytes: [UInt8]) -> BeaconInfo? {
        InformationElements.parse(Data(bytes))
    }

    /// RSN: CCMP di gruppo, pairwise CCMP + TKIP, AKM PSK + SAE.
    private let rsnPSKSAE: [UInt8] = [
        0x01, 0x00,                   // version
        0x00, 0x0F, 0xAC, 0x04,       // group: CCMP
        0x02, 0x00,                   // pairwise count
        0x00, 0x0F, 0xAC, 0x04,       // CCMP
        0x00, 0x0F, 0xAC, 0x02,       // TKIP
        0x02, 0x00,                   // AKM count
        0x00, 0x0F, 0xAC, 0x02,       // PSK
        0x00, 0x0F, 0xAC, 0x08,       // SAE
    ]

    @Test func nilAndEmptyData() {
        #expect(InformationElements.parse(nil) == nil)
        #expect(InformationElements.parse(Data()) == nil)
    }

    @Test func bssLoad() throws {
        let info = try #require(parse(tlv(11, [0x2A, 0x00, 0x80, 0x00, 0x00])))
        #expect(info.stationCount == 42)
        #expect(abs((info.channelUtilization ?? -1) - 128.0 / 255) < 1e-9)
    }

    @Test func wifiGenerationKeepsMaximum() throws {
        let ht = try #require(parse(tlv(45, [0x00])))
        #expect(ht.wifiGeneration == 4)

        let vht = try #require(parse(tlv(45, [0x00]) + tlv(191, [0x00])))
        #expect(vht.wifiGeneration == 5)

        let he = try #require(parse(tlv(191, [0x00]) + tlv(255, [35, 0x00])))
        #expect(he.wifiGeneration == 6)

        let eht = try #require(parse(tlv(255, [35, 0x00]) + tlv(255, [108, 0x00]) + tlv(45, [0x00])))
        #expect(eht.wifiGeneration == 7)
    }

    @Test func unknownExtensionIgnored() {
        #expect(parse(tlv(255, [99, 0x00]))?.wifiGeneration == nil)
    }

    @Test func rsnSecurityAndTKIP() throws {
        let info = try #require(parse(tlv(48, rsnPSKSAE)))
        #expect(info.security == ["WPA2-PSK", "WPA3-SAE"])
        #expect(info.hasTKIP)
    }

    @Test func rsnGroupTKIPSetsFlag() throws {
        let bytes: [UInt8] = [
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x02,   // group: TKIP
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x04,   // CCMP
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x02,   // PSK
        ]
        let info = try #require(parse(tlv(48, bytes)))
        #expect(info.hasTKIP)
        #expect(info.security == ["WPA2-PSK"])
    }

    @Test func rsnAKMNamesAndDeduplication() throws {
        let bytes: [UInt8] = [
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x04,
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x04,
            0x03, 0x00,
            0x00, 0x0F, 0xAC, 0x02,   // PSK
            0x00, 0x0F, 0xAC, 0x01,   // 802.1X
            0x00, 0x0F, 0xAC, 0x02,   // PSK di nuovo: non duplicato
        ]
        let info = try #require(parse(tlv(48, bytes)))
        #expect(info.security == ["WPA2-PSK", "802.1X"])
        #expect(!info.hasTKIP)
    }

    @Test func rsnOWEAndUnknownOUI() throws {
        let bytes: [UInt8] = [
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x04,
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x04,
            0x02, 0x00,
            0x00, 0x0F, 0xAC, 0x12,   // OWE
            0x00, 0x50, 0xF2, 0x02,   // OUI non 00-0F-AC: ignorato
        ]
        let info = try #require(parse(tlv(48, bytes)))
        #expect(info.security == ["OWE"])
    }

    @Test func vendorWPAAndWPS() throws {
        let info = try #require(parse(tlv(221, [0x00, 0x50, 0xF2, 0x01]) + tlv(221, [0x00, 0x50, 0xF2, 0x01])))
        #expect(info.security == ["WPA"])

        let wps = try #require(parse(tlv(221, [0x00, 0x50, 0xF2, 0x04])))
        #expect(wps.wps)
        #expect(wps.security.isEmpty)
    }

    @Test func vendorWPAKeepsOrderOfAppearance() throws {
        let info = try #require(parse(tlv(221, [0x00, 0x50, 0xF2, 0x01]) + tlv(48, rsnPSKSAE)))
        #expect(info.security == ["WPA", "WPA2-PSK", "WPA3-SAE"])
    }

    @Test func otherVendorOUIIgnored() {
        let info = parse(tlv(221, [0x00, 0x10, 0x18, 0x01]) + tlv(221, [0x00, 0x50, 0xF2, 0x04]))
        #expect(info?.security.isEmpty == true)
        #expect(info?.wps == true)
    }

    @Test func capabilityFlags() throws {
        let info = try #require(parse(tlv(70, [0, 0, 0, 0, 0]) + tlv(54, [0, 0, 0])))
        #expect(info.supports11k)
        #expect(info.supports11r)
        #expect(!info.supports11v)
    }

    @Test func extendedCapabilitiesBit19() throws {
        let set = try #require(parse(tlv(127, [0x00, 0x00, 0x08])))
        #expect(set.supports11v)

        let clear = try #require(parse(tlv(127, [0x00, 0x00, 0x00])))
        #expect(!clear.supports11v)
    }

    @Test func truncatedIELengthStops() throws {
        // BSS Load dichiara 5 byte ma ne ha 2: nessun campo.
        let info = try #require(parse([11, 5, 0x2A, 0x00]))
        #expect(info.stationCount == nil)
        #expect(info.channelUtilization == nil)
    }

    @Test func truncatedHeaderStops() throws {
        // Un IE completo seguito da un solo byte di id: il primo vale, il secondo no.
        let info = try #require(parse(tlv(54, [0, 0, 0]) + [45]))
        #expect(info.supports11r)
        #expect(info.wifiGeneration == nil)
    }

    @Test func singleByteData() throws {
        let info = try #require(parse([0x36]))
        #expect(info == BeaconInfo())
    }

    @Test func truncatedRSNHeaderIgnored() throws {
        let info = try #require(parse(tlv(48, [0x01, 0x00, 0x00, 0x0F])))
        #expect(info.security.isEmpty)
        #expect(!info.hasTKIP)
    }

    @Test func truncatedRSNAKMListKeepsCompleteEntries() throws {
        // Dichiara 2 AKM, ma l'ultimo è troncato: resta solo PSK.
        let cut = Array(rsnPSKSAE.dropLast(2))
        let info = try #require(parse(tlv(48, cut)))
        #expect(info.security == ["WPA2-PSK"])
        #expect(info.hasTKIP)
    }

    @Test func truncatedVendorIgnored() throws {
        let info = try #require(parse(tlv(221, [0x00, 0x50])))
        #expect(info.security.isEmpty)
        #expect(!info.wps)
    }
}
