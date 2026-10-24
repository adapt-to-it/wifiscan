import Foundation

/// Algebra 5.1 e vocabolario 5.2.
public enum Symptoms {
    /// Espressione del sintomo nel contesto dato (K5 e K6 entrano come `scale`).
    public static func expression(_ id: SymptomID, context: DiagnosisContext) -> Expr {
        let localScale = 1 - context.icmpPenalty
        let trafficScale = context.backgroundTraffic ? 0.5 : 1.0
        switch id {
        case .s1: return .feature(.f1)
        case .s2: return .scale(.feature(.f20), localScale)
        case .s3: return .scale(.feature(.f22), localScale)
        case .s4: return .scale(.feature(.f23), localScale)
        case .s5: return .scale(.scale(.feature(.f28), localScale), trafficScale)
        // S6: gonfiamento oltre il router. F29x e l'RPM (F63) misurano lo stesso fenomeno, quindi
        // entrano in un gruppo (5.1) e non si sommano.
        case .s6: return .scale(.group([.feature(.f29x), .feature(.f63)]), trafficScale)
        case .s7: return .feature(.f24)
        case .s8: return .feature(.f25)
        case .s9: return .feature(.f61)
        case .s10: return .and(.feature(.f40), .feature(.f41))
        case .s11: return .feature(.f60)
        case .s12: return .feature(.f9)
        case .s13: return .feature(.f6)
        case .s14: return .feature(.f62)
        }
    }

    public static func evaluate(_ expr: Expr, features: FeatureSet) -> Graded {
        switch expr {
        case .feature(let id):
            let graded = features[id]
            return graded.isMissing ? .missing : graded
        case .not(let inner):
            let graded = evaluate(inner, features: features)
            return graded.isMissing ? .missing : Graded(1 - graded.grade, confidence: graded.confidence)
        case .and(let lhs, let rhs):
            let graded = available([lhs, rhs], features: features)
            guard let first = graded.first else { return .missing }
            return graded.dropFirst().reduce(first) { acc, next in
                Graded(min(acc.grade, next.grade), confidence: min(acc.confidence, next.confidence))
            }
        case .or(let lhs, let rhs):
            // Vince il termine con il grado massimo; a parità, quello con confidenza maggiore.
            return available([lhs, rhs], features: features)
                .max { ($0.grade, $0.confidence) < ($1.grade, $1.confidence) } ?? .missing
        case .group(let exprs):
            let graded = available(exprs, features: features)
            guard !graded.isEmpty else { return .missing }
            return Graded(graded.map(\.grade).max() ?? 0, confidence: graded.map(\.confidence).max() ?? 0)
        case .scale(let inner, let k):
            let graded = evaluate(inner, features: features)
            return Graded(graded.grade, confidence: k * graded.confidence)
        }
    }

    /// Tutti i sintomi; un sintomo con confidenza sotto 0,3 vale `.missing`.
    public static func all(_ features: FeatureSet) -> [SymptomID: Graded] {
        var result: [SymptomID: Graded] = [:]
        for id in SymptomID.allCases {
            let graded = evaluate(expression(id, context: features.context), features: features)
            result[id] = graded.isMissing ? .missing : graded
        }
        return result
    }

    /// Termini valutati che non sono mancanti: `and`, `or` e `group` ignorano gli altri.
    private static func available(_ exprs: [Expr], features: FeatureSet) -> [Graded] {
        exprs.map { evaluate($0, features: features) }.filter { !$0.isMissing }
    }
}
