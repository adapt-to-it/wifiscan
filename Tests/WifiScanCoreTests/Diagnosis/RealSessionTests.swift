import Foundation
import Testing
@testable import WifiScanCore

/// Sessioni reali etichettate (sezione 12.5). Sono il criterio di accettazione del motore.
@Suite struct RealSessionTests {
    static func load(_ name: String) throws -> DiagnosisSession {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try SessionRecorder.load(url)
    }

    @Test func exitNodeSessionPointsToVPN() throws {
        let session = try Self.load("exit-node-1")
        let now = try #require(session.probes.map(\.t).max())
        let report = DiagnosisEngine.diagnose(session, now: now)

        print("esito:", report.outcome)
        for (set, p) in report.posterior.sets.prefix(5) {
            print(String(format: "  %.3f", p), set.map(\.rawValue).sorted())
        }
        for s in SymptomID.allCases {
            if let g = report.symptoms[s] { print("  \(s.rawValue): \(g)") }
        }
        for (id, text) in report.actions { print("  \(id.rawValue): \(text)") }

        // Criterio 12.4: V1 diagnosticata, oppure esito ambiguo che la include
        // e propone un test che la separa dall'alternativa.
        switch report.outcome {
        case .diagnosis(let causes):
            #expect(causes.contains(.v1))
        case .ambiguous(let first, let second, let test):
            #expect(first.union(second).contains(.v1))
            let separates = Catalog.tests[test]?.separates ?? []
            #expect(separates.contains(.v1))
        default:
            Issue.record("esito inatteso: \(report.outcome)")
        }
        // Wi-Fi sano: la radio non è tra le cause.
        #expect((report.posterior.marginals[.r1] ?? 0) < 0.2)
    }

    /// Sessione far-from-router-1: vicino al router fino a 4 min, SNR fino a 1 dB al minuto 5, poi ritorno.
    @Test func farFromRouterSessionFollowsTheWalk() throws {
        let session = try Self.load("far-from-router-1")
        let t0 = try #require(session.probes.map(\.t).min())
        func report(_ sec: Double) -> DiagnosisReport {
            DiagnosisEngine.diagnose(session, now: t0.addingTimeInterval(sec))
        }
        // Vicino al router: nessuna causa sopra 0,4.
        let near = report(150)
        #expect(near.posterior.marginals.filter { $0.key != .unknown && $0.value >= 0.4 }.isEmpty)
        // Nel punto più lontano: segnale debole diagnosticato.
        if case .diagnosis(let causes) = report(300).outcome {
            #expect(causes.contains(.r1))
        } else {
            Issue.record("a 300 s atteso diagnosis con r1, ottenuto \(report(300).outcome)")
        }
        // Il Wi-Fi che perde metà dei pacchetti non diventa un'interruzione di linea né una penalità ICMP.
        for sec in stride(from: 120.0, through: 390, by: 30) {
            let r = report(sec)
            #expect((r.posterior.marginals[.w6] ?? 0) < 0.4, "W6 a \(sec) s")
            #expect(r.features.context.icmpPenalty < 0.5, "K6 a \(sec) s")
        }
    }

    /// Sessione healthy-home-1: rete di casa, Mac fermo vicino al router. Il motore deve tacere.
    @Test func healthyHomeSessionStaysSilent() throws {
        let session = try Self.load("healthy-home-1")
        let t0 = try #require(session.probes.map(\.t).min())
        for sec in stride(from: 120.0, through: 540, by: 30) {
            let r = DiagnosisEngine.diagnose(session, now: t0.addingTimeInterval(sec))
            if case .healthy = r.outcome {} else { Issue.record("a \(sec) s esito \(r.outcome)") }
            #expect(r.posterior.marginals.filter { $0.key != .unknown && $0.value >= 0.4 }.isEmpty, "a \(sec) s")
        }
    }

    /// Sessione exit-node-2: rete esterna, exit node diretto. A riposo aggiunge solo latenza;
    /// sotto carico il tunnel perde il 67 % dei pacchetti mentre il router resta a 4 ms.
    @Test func directExitNodeSessionIsQuietAtRestAndBlamesVPNUnderLoad() throws {
        let session = try Self.load("exit-node-2")
        let t0 = try #require(session.probes.map(\.t).min())
        let end = try #require(session.probes.map(\.t).max())
        for sec in stride(from: 120.0, through: 840, by: 120) {
            let r = DiagnosisEngine.diagnose(session, now: t0.addingTimeInterval(sec))
            guard case .healthy = r.outcome else {
                Issue.record("a \(Int(sec)) s esito inatteso: \(r.outcome)"); continue
            }
        }
        let r = DiagnosisEngine.diagnose(session, now: end)
        guard case .diagnosis(let causes) = r.outcome else {
            Issue.record("esito finale inatteso: \(r.outcome)"); return
        }
        #expect(causes.contains(.v1))
        #expect((r.posterior.marginals[.r1] ?? 0) < 0.2)
    }

    /// Sessione no-exit-node-1: linea di casa sana a riposo, bufferbloat moderato sotto carico
    /// (internet a 120–240 ms negli ultimi 9 s del test, router a 6–10 ms, 180 RPM).
    @Test func homeLineBufferbloatIsSeenUnderLoad() throws {
        let session = try Self.load("no-exit-node-1")
        let end = try #require(session.probes.map(\.t).max())
        let r = DiagnosisEngine.diagnose(session, now: end)
        print("esito:", r.outcome, r.posterior.marginals.sorted { $0.value > $1.value }.prefix(3))
        switch r.outcome {
        case .diagnosis(let causes):
            #expect(causes.contains(.w1))
        case .probable(let cause, _):
            #expect(cause == .w1)
        case .ambiguous(let first, let second, _):
            #expect(first.union(second).contains(.w1))
        default:
            Issue.record("esito inatteso: \(r.outcome)")
        }
        #expect((r.posterior.marginals[.r1] ?? 0) < 0.2)
    }

    /// Sessione mixed-1: prima rete con segnale debole (RSSI −69/−73), Mac sospeso da 637 a 869 s,
    /// cambio di rete a 890 s, test sotto carico finale con internet in perdita e 71 RPM.
    @Test func networkChangeStartsAFreshAnalysis() throws {
        let session = try Self.load("mixed-1")
        let t0 = try #require(session.probes.map(\.t).min())
        let end = try #require(session.probes.map(\.t).max())
        func report(_ sec: Double) -> DiagnosisReport { DiagnosisEngine.diagnose(session, now: t0.addingTimeInterval(sec)) }

        guard case .diagnosis(let first) = report(480).outcome else {
            Issue.record("a 480 s esito inatteso: \(report(480).outcome)"); return
        }
        #expect(first.contains(.r1))
        // Dopo il cambio di rete le misure della rete precedente non contano più.
        for sec in [900.0, 1020, 1080] {
            #expect((report(sec).posterior.marginals[.r1] ?? 0) < 0.2, "a \(Int(sec)) s")
            #expect((report(sec).posterior.marginals[.g1] ?? 0) < 0.2, "a \(Int(sec)) s")
        }
        let last = DiagnosisEngine.diagnose(session, now: end)
        guard case .diagnosis(let causes) = last.outcome else {
            Issue.record("esito finale inatteso: \(last.outcome)"); return
        }
        #expect(causes.contains(.w1))
    }
}

