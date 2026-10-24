import Foundation
import Testing
@testable import WifiScanCore

@Suite struct CatalogTests {

    @Test func catalogHasElevenCausesWithAllIDs() {
        let ids = Catalog.model.causes.map(\.id)
        #expect(ids.count == 11)
        #expect(Set(ids) == Set(CauseID.allCases))
    }

    @Test func catalogHasTwelveTests() {
        #expect(Set(Catalog.tests.keys) == Set(TestID.allCases))
    }

    @Test func r1GateIsFalseWithEthernet() {
        let r1 = Catalog.model.causes.first { $0.id == .r1 }!
        #expect(!r1.gate(DiagnosisContext(ethernet: true)))
        #expect(r1.gate(DiagnosisContext(ethernet: false)))
    }

    @Test func w1PriorDependsOnVPN() {
        let w1 = Catalog.model.causes.first { $0.id == .w1 }!
        #expect(w1.prior(DiagnosisContext(vpnDefaultRoute: false)) == 0.20)
        #expect(w1.prior(DiagnosisContext(vpnDefaultRoute: true)) == 0.10)
    }

    @Test func renderFormatsIntegersWithoutDecimalsAndOthersWithOne() {
        let text = Catalog.render("<channel> <channelUtilizationPct> <outagesPerHour>",
                                  details: [.channel: 6, .channelUtilizationPct: 62.44, .outagesPerHour: 3])
        #expect(text == "6 62.4 3")
    }

    @Test func renderUsesDashForMissingOrUnknownKeys() {
        #expect(Catalog.render("<lossInternetPct> <nonEsiste>", details: [:]) == "— —")
    }

    @Test func everyQIsBetweenZeroAndOne() {
        for cause in Catalog.model.causes {
            for (_, q) in cause.q {
                #expect((0...1).contains(q))
            }
        }
    }
}
