import Foundation
import Testing
@testable import WifiScanCore

@Suite struct NetworkAlertsTests {
    private let gw = "192.168.1.1"
    private let gwMAC = "aa:bb:cc:dd:ee:ff"

    @Test func gatewayMACChangedWhenDifferentFromPrevious() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [ARPObservation(ip: gw, mac: gwMAC)], devices: [],
            gatewayIP: gw, previousGatewayMAC: "11:22:33:44:55:66")
        let alert = alerts.first { $0.kind == .gatewayMACChanged }
        #expect(alert?.id == "gatewayMACChanged-\(gw)")
        #expect(alert?.severity == .critical)
    }

    @Test func gatewayMACUnchangedWhenSameIgnoringCase() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [ARPObservation(ip: gw, mac: gwMAC)], devices: [],
            gatewayIP: gw, previousGatewayMAC: gwMAC.uppercased())
        #expect(!alerts.contains { $0.kind == .gatewayMACChanged })
    }

    @Test func gatewayMACChangedNotRaisedWithoutPrevious() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [ARPObservation(ip: gw, mac: gwMAC)], devices: [],
            gatewayIP: gw, previousGatewayMAC: nil)
        #expect(!alerts.contains { $0.kind == .gatewayMACChanged })
    }

    @Test func gatewayMACDuplicatedOnAnotherIP() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [
                ARPObservation(ip: gw, mac: gwMAC),
                ARPObservation(ip: "192.168.1.20", mac: gwMAC.uppercased()),
            ], devices: [], gatewayIP: gw, previousGatewayMAC: nil)
        let alert = alerts.first { $0.kind == .gatewayMACDuplicated }
        #expect(alert?.id == "gatewayMACDuplicated-\(gw)")
        #expect(alert?.severity == .critical)
        #expect(alert?.detail.contains("192.168.1.20") == true)
    }

    @Test func gatewayMACNotDuplicatedWhenOnlyGateway() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [ARPObservation(ip: gw, mac: gwMAC)], devices: [],
            gatewayIP: gw, previousGatewayMAC: nil)
        #expect(alerts.isEmpty)
    }

    @Test func gatewayRulesSkippedWithoutGatewayIP() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [
                ARPObservation(ip: gw, mac: gwMAC),
                ARPObservation(ip: "192.168.1.20", mac: gwMAC),
            ], devices: [], gatewayIP: nil, previousGatewayMAC: "11:22:33:44:55:66")
        #expect(!alerts.contains { $0.kind == .gatewayMACChanged || $0.kind == .gatewayMACDuplicated })
        #expect(alerts.isEmpty)
    }

    @Test func gatewayRulesSkippedWhenGatewayNotObserved() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [ARPObservation(ip: "192.168.1.20", mac: gwMAC)], devices: [],
            gatewayIP: gw, previousGatewayMAC: "11:22:33:44:55:66")
        #expect(alerts.isEmpty)
    }

    @Test func ipConflictWithTwoMACs() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [
                ARPObservation(ip: "192.168.1.5", mac: "00:11:22:33:44:55"),
                ARPObservation(ip: "192.168.1.5", mac: "00:11:22:33:44:66"),
            ], devices: [], gatewayIP: nil, previousGatewayMAC: nil)
        let alert = alerts.first { $0.kind == .ipConflict }
        #expect(alert?.id == "ipConflict-192.168.1.5")
        #expect(alert?.severity == .warning)
    }

    @Test func ipConflictNotRaisedForSameMACInDifferentCase() {
        let alerts = NetworkAlertDetector.evaluate(
            observations: [
                ARPObservation(ip: "192.168.1.5", mac: "00:11:22:AA:44:55"),
                ARPObservation(ip: "192.168.1.5", mac: "00:11:22:aa:44:55"),
            ], devices: [], gatewayIP: nil, previousGatewayMAC: nil)
        #expect(!alerts.contains { $0.kind == .ipConflict })
    }

    @Test func newDeviceAlertWithDetail() {
        let device = LanDevice(ip: "192.168.1.9", mac: "00:aa:bb:cc:dd:ee", vendor: "Acme", isNew: true)
        let alerts = NetworkAlertDetector.evaluate(
            observations: [], devices: [device], gatewayIP: nil, previousGatewayMAC: nil)
        let alert = alerts.first { $0.kind == .newDevice }
        #expect(alert?.id == "newDevice-192.168.1.9")
        #expect(alert?.severity == .info)
        #expect(alert?.detail.contains("192.168.1.9") == true)
        #expect(alert?.detail.contains("Acme") == true)
        #expect(alert?.detail.contains("00:aa:bb:cc:dd:ee") == true)
    }

    @Test func newDeviceSkippedWhenThisMacOrNotNew() {
        let thisMac = LanDevice(ip: "192.168.1.2", mac: "00:00:00:00:00:01", isThisMac: true, isNew: true)
        let old = LanDevice(ip: "192.168.1.3", mac: "00:00:00:00:00:02", isNew: false)
        let alerts = NetworkAlertDetector.evaluate(
            observations: [], devices: [thisMac, old], gatewayIP: nil, previousGatewayMAC: nil)
        #expect(alerts.isEmpty)
    }

    @Test func alertsSortedBySeverityThenID() {
        let device = LanDevice(ip: "192.168.1.9", isNew: true)
        let alerts = NetworkAlertDetector.evaluate(
            observations: [
                ARPObservation(ip: gw, mac: gwMAC),
                ARPObservation(ip: "192.168.1.20", mac: gwMAC),
                ARPObservation(ip: "192.168.1.5", mac: "00:11:22:33:44:55"),
                ARPObservation(ip: "192.168.1.5", mac: "00:11:22:33:44:66"),
            ],
            devices: [device], gatewayIP: gw, previousGatewayMAC: "11:22:33:44:55:66")
        #expect(alerts.map(\.id) == [
            "gatewayMACChanged-\(gw)",
            "gatewayMACDuplicated-\(gw)",
            "ipConflict-192.168.1.5",
            "newDevice-192.168.1.9",
        ])
        #expect(alerts.map(\.severity) == [.critical, .critical, .warning, .info])
    }
}
