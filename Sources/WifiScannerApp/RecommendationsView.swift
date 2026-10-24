import SwiftUI
import WifiScanCore

struct RecommendationsView: View {
    let vm: ScanViewModel

    var body: some View {
        let recs = vm.recommendations
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if recs.isEmpty {
                    EmptyStateView(text: "Esegui uno scan per vedere i suggerimenti.")
                } else {
                    ForEach(recs, id: \.suggestedChannel) { rec in
                        RecommendationCard(rec: rec)
                    }
                    GeneralAdviceCard()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecommendationCard: View {
    let rec: Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: rec.band == .ghz24 ? "antenna.radiowaves.left.and.right" : "wifi")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(rec.band.rawValue)
                    .font(.title3.weight(.semibold))
                Spacer()
                if rec.isAlreadyOptimal {
                    Label("Ottimale", systemImage: "checkmark.seal.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background { Capsule().fill(Color.green.opacity(0.18)) }
                        .foregroundStyle(.green)
                }
            }

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Canale consigliato")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(rec.suggestedChannel)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                        Text("@ \(rec.suggestedWidth) MHz")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let cur = rec.currentChannel, cur != rec.suggestedChannel {
                    Divider().frame(height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Canale attuale")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text("\(cur)")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                if let imp = rec.improvementScore, imp > 0.01, !rec.isAlreadyOptimal {
                    Divider().frame(height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Miglioramento")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.right")
                            Text(String(format: "%.2f", imp))
                                .monospacedDigit()
                        }
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }

            Text(rec.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.secondary)
        }
    }
}

struct GeneralAdviceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Linee guida pratiche", systemImage: "info.circle")
                .font(.headline)
                .foregroundStyle(.secondary)

            advice("5 GHz", "Preferisci canali non-DFS (36-48 o 149-161): evitano interruzioni di 1-10 min se passa un radar meteo.")
            advice("Larghezza 80 MHz", "Bilanciamento ideale per casa singola. Evita 160 MHz in ambienti densi: aumenta la velocità teorica ma peggiora la stabilità.")
            advice("2.4 GHz", "Solo canali 1, 6 o 11. Mai 40 MHz su 2.4 GHz: occupa metà banda e disturba i vicini.")
            advice("Scoring", "Reti sotto −85 dBm sono ignorate (CCA threshold). APs virtuali sullo stesso router sono deduplicati.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.tertiary)
        }
    }

    private func advice(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
