import Foundation
import Testing
@testable import WifiScanCore

@Suite struct DiagnosisMonitorTests {

    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func interval(_ from: TimeInterval, _ to: TimeInterval) -> ActivityInterval {
        ActivityInterval(kind: .wifiScan, start: base.addingTimeInterval(from), end: base.addingTimeInterval(to))
    }

    @Test func timestampInsideIntervalIsContaminated() {
        let intervals = [interval(10, 20)]
        #expect(DiagnosisMonitor.isContaminated(base.addingTimeInterval(15), by: intervals))
    }

    @Test func timestampWithinMarginAfterEndIsContaminated() {
        let intervals = [interval(10, 20)]
        #expect(DiagnosisMonitor.isContaminated(base.addingTimeInterval(20.4), by: intervals))
    }

    @Test func timestampBeyondMarginIsNotContaminated() {
        let intervals = [interval(10, 20)]
        #expect(!DiagnosisMonitor.isContaminated(base.addingTimeInterval(20.6), by: intervals))
    }

    @Test func timestampBeforeStartIsNotContaminated() {
        let intervals = [interval(10, 20)]
        #expect(!DiagnosisMonitor.isContaminated(base.addingTimeInterval(9.9), by: intervals))
    }

    @Test func emptyIntervalsAreNotContaminated() {
        #expect(!DiagnosisMonitor.isContaminated(base, by: []))
    }
}
