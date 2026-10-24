import Foundation
import Testing
@testable import WifiScanCore

// Proprietà che il motore deve rispettare su tutti gli scenari avversari (DIAGNOSI.md, 12.1).
// Le soglie non sono tarate: un fallimento qui è un risultato da riportare, non un bug da mascherare.

@Suite struct AdversarialTests {
    /// Scenari la cui firma misurata coincide con una causa del catalogo: il motore non può
    /// distinguerli, quindi la diagnosi di quella causa non è un errore.
    /// - ipv6-rotto: resolver di sistema lento e 1.1.1.1 sano è la firma esatta di D1.
    ///   DNSProber interroga il resolver via UDP, quindi un IPv6 rotto non produce comunque questa misura.
    static let indistinguishable: Set<String> = ["ipv6-rotto"]

    @Test func noConfidentCauseOtherThanUnknown() {
        var violations: [String] = []
        for (name, session) in AdversarialScenarios.all() where !Self.indistinguishable.contains(name) {
            let report = DiagnosisEngine.diagnose(session, now: adversarialNow(session))
            let confident = report.posterior.marginals.filter { $0.key != .unknown && $0.value >= 0.7 }
            if !confident.isEmpty {
                violations.append(name)
                print("FALLITO (nessuna causa oltre ignota con marginale >= 0,7) " + adversarialSummary(name, report))
            }
        }
        #expect(violations.count == 0)
    }

    @Test func posteriorSetsSumToOne() {
        var violations: [String] = []
        for (name, session) in AdversarialScenarios.all() {
            let report = DiagnosisEngine.diagnose(session, now: adversarialNow(session))
            let total = report.posterior.sets.reduce(0.0) { $0 + $1.probability }
            if abs(total - 1) > 1e-6 {
                violations.append(name)
                print("FALLITO (somma delle probabilita dei set = \(total)) " + adversarialSummary(name, report))
            }
        }
        #expect(violations.count == 0)
    }

    @Test func noDiagnosisOutcome() {
        var violations: [String] = []
        for (name, session) in AdversarialScenarios.all() where !Self.indistinguishable.contains(name) {
            let report = DiagnosisEngine.diagnose(session, now: adversarialNow(session))
            if case .diagnosis = report.outcome {
                violations.append(name)
                print("FALLITO (esito diagnosis) " + adversarialSummary(name, report))
            }
        }
        #expect(violations.count == 0)
    }
}

/// Istante di riferimento per il motore: il campione di probe più recente.
private func adversarialNow(_ session: DiagnosisSession) -> Date {
    session.probes.map(\.t).max() ?? session.meta.start
}

/// Riga di diagnostica: nome dello scenario, esito e i tre marginali più alti.
private func adversarialSummary(_ name: String, _ report: DiagnosisReport) -> String {
    let top = report.posterior.marginals
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
        .prefix(3)
        .map { "\($0.key.rawValue)=\(String(format: "%.3f", $0.value))" }
    return "[\(name)] esito=\(report.outcome) marginali=\(top.joined(separator: ", "))"
}
