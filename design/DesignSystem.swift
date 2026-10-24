//  DesignSystem.swift
//  Componenti riutilizzabili per l'app Wi‑Fi (macOS 14+, SwiftUI + Swift Charts).
//  Un solo file: token, soglie (numeri → parole), modalità Semplice/Esperto e componenti.

import SwiftUI
import Charts
import AppKit

// MARK: - Token

enum DS {
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
        static let xl: CGFloat = 20, xxl: CGFloat = 24, xxxl: CGFloat = 32
    }
    enum Radius {
        static let control: CGFloat = 6, tile: CGFloat = 10, card: CGFloat = 12
    }
}

extension Color {
    /// Superficie delle card: #232326 in scuro, bianco in chiaro.
    static let dsSurface = Color(nsColor: NSColor(name: "dsSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.137, green: 0.137, blue: 0.149, alpha: 1)
            : .white
    })
    /// Bordo sottile delle card.
    static let dsHairline = Color(nsColor: .separatorColor)
}

// MARK: - Giudizio (numeri → parole)

enum StatusLevel: String, CaseIterable, Sendable {
    case great, good, fair, poor, info, unknown

    var label: String {
        switch self {
        case .great: "Ottimo"
        case .good: "Buono"
        case .fair: "Discreto"
        case .poor: "Scarso"
        case .info: "Info"
        case .unknown: "Non misurato"
        }
    }

    var symbol: String {
        switch self {
        case .great: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .fair: "exclamationmark.triangle.fill"
        case .poor: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        case .unknown: "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .great, .good: .green
        case .fair: .orange
        case .poor: .red
        case .info: .accentColor
        case .unknown: .gray
        }
    }
}

enum SecurityKind: Sendable { case wpa3, wpa2, mixedWPA, open, wep }

/// Unica fonte delle soglie: la usano viste, diagnosi e report PDF.
enum Thresholds {
    static func rssi(_ dBm: Int) -> StatusLevel {
        dBm >= -60 ? .great : dBm >= -67 ? .good : dBm >= -75 ? .fair : .poor
    }
    static func snr(_ dB: Int) -> StatusLevel {
        dB >= 30 ? .great : dB >= 20 ? .good : dB >= 13 ? .fair : .poor
    }
    static func gatewayLatency(_ ms: Double) -> StatusLevel {
        ms < 10 ? .great : ms < 30 ? .good : ms < 80 ? .fair : .poor
    }
    static func internetLatency(_ ms: Double) -> StatusLevel {
        ms < 30 ? .great : ms < 60 ? .good : ms < 120 ? .fair : .poor
    }
    static func packetLoss(_ percent: Double) -> StatusLevel {
        percent == 0 ? .great : percent < 1 ? .good : percent <= 3 ? .fair : .poor
    }
    static func channelLoad(_ score: Double) -> StatusLevel {
        score < 0.3 ? .great : score < 0.6 ? .good : score <= 0.9 ? .fair : .poor
    }
    static func channelLoadWord(_ score: Double) -> String {
        score < 0.3 ? "Libero" : score < 0.6 ? "Poco usato" : score <= 0.9 ? "Affollato" : "Saturo"
    }
    static func security(_ kind: SecurityKind) -> StatusLevel {
        switch kind {
        case .wpa3: .great
        case .wpa2: .good
        case .mixedWPA: .fair
        case .open, .wep: .poor
        }
    }
}

// MARK: - Modalità Semplice / Esperto

enum DetailMode: String, CaseIterable, Identifiable, Sendable {
    case simple, expert
    var id: String { rawValue }
    var title: String { self == .simple ? "Semplice" : "Esperto" }
}

private struct DetailModeKey: EnvironmentKey {
    static let defaultValue: DetailMode = .simple
}

extension EnvironmentValues {
    var detailMode: DetailMode {
        get { self[DetailModeKey.self] }
        set { self[DetailModeKey.self] = newValue }
    }
}

/// Va nella toolbar della finestra. Esempio:
/// `.toolbar { ToolbarItem { ModeToggle() } }` e, sulla root,
/// `.environment(\.detailMode, mode)` con `@AppStorage("detailMode") var mode: DetailMode = .simple`.
struct ModeToggle: View {
    @AppStorage("detailMode") private var mode: DetailMode = .simple
    var body: some View {
        Picker("Livello di dettaglio", selection: $mode) {
            ForEach(DetailMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Esperto mostra BSSID, dBm, punteggi e indirizzi MAC")
    }
}

/// Mostra il contenuto solo in modalità Esperto.
struct ExpertOnly<Content: View>: View {
    @Environment(\.detailMode) private var mode
    @ViewBuilder var content: Content
    var body: some View { if mode == .expert { content } }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let level: StatusLevel
    var text: String? = nil

    var body: some View {
        Label(text ?? level.label, systemImage: level.symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(level.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(level.color.opacity(0.16), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

// MARK: - SignalBars

struct SignalBars: View {
    let rssi: Int
    var body: some View {
        let level = Thresholds.rssi(rssi)
        let value: Double = switch level {
        case .great: 1.0
        case .good: 0.75
        case .fair: 0.5
        default: 0.25
        }
        Image(systemName: "cellularbars", variableValue: value)
            .foregroundStyle(level.color)
            .accessibilityLabel("Segnale \(level.label.lowercased()), \(rssi) dBm")
    }
}

// MARK: - TagChip

struct TagChip: View {
    enum Kind {
        case you, new, privateAddress, dfs, yourNetwork
        var text: String {
            switch self {
            case .you: "TU"
            case .new: "NUOVO"
            case .privateAddress: "INDIRIZZO PRIVATO"
            case .dfs: "DFS"
            case .yourNetwork: "TUA RETE"
            }
        }
        var color: Color {
            switch self {
            case .you: .accentColor
            case .new: .orange
            case .privateAddress: .purple
            case .dfs: .gray
            case .yourNetwork: .green
            }
        }
        var help: String {
            switch self {
            case .you: "Questo Mac."
            case .new: "Visto per la prima volta da poco."
            case .privateAddress: "iPhone, Android e Windows cambiano indirizzo per privacy. È normale."
            case .dfs: "Canale condiviso con i radar meteo: il router può spostarsi da solo per circa un minuto."
            case .yourNetwork: "Una rete del tuo router."
            }
        }
    }

    let kind: Kind
    var body: some View {
        Text(kind.text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(kind.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
            .help(kind.help)
    }
}

// MARK: - HealthGauge

struct HealthGauge: View {
    let score: Int          // 0…100
    let level: StatusLevel
    var size: CGFloat = 132

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.08)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(level.color, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("su 100").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Punteggio \(score) su 100, \(level.label)")
    }
}

// MARK: - MetricTile

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    let level: StatusLevel
    var badge: String? = nil
    var raw: String? = nil   // visibile solo in Esperto

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title.weight(.semibold)).monospacedDigit()
                if let unit { Text(unit).font(.body).foregroundStyle(.secondary) }
            }
            StatusBadge(level: level, text: badge)
            if let raw {
                ExpertOnly { Text(raw).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: DS.Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile).strokeBorder(Color.dsHairline))
    }
}

// MARK: - SectionCard

struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String? = nil
    var footnote: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                if let symbol {
                    Label(title, systemImage: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary, Color.accentColor)
                } else {
                    Text(title)
                }
                Spacer()
                accessory
            }
            .font(.title3.weight(.semibold))
            content
            if let footnote {
                Text(footnote).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.Space.l)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsHairline))
    }
}

extension SectionCard where Accessory == EmptyView {
    init(_ title: String, symbol: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.footnote = footnote
        self.accessory = EmptyView()
        self.content = content()
    }
}

// MARK: - KeyValueRow

struct KeyValueRow: View {
    let title: String
    let value: String
    var level: StatusLevel? = nil
    var monospaced = false
    var help: String? = nil
    var expertOnly = false

    @Environment(\.detailMode) private var mode
    @State private var showHelp = false

    var body: some View {
        if expertOnly && mode == .simple {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(monospaced ? .body.monospaced() : .body)
                if let level { StatusBadge(level: level) }
                if let help {
                    Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cos'è \(title.lowercased())")
                        .popover(isPresented: $showHelp, arrowEdge: .trailing) {
                            Text(help).padding().frame(width: 260)
                        }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - InsightRow

struct InsightRow: View {
    let level: StatusLevel
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: level.symbol)
                .foregroundStyle(level.color)
                .frame(width: 30, height: 30)
                .background(level.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.m)
            if let actionTitle {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(.vertical, DS.Space.m)
    }
}

// MARK: - CheckStepRow

struct CheckStepRow: View {
    enum State { case pending, running, passed, warning, failed, info }
    let title: String
    var detail: String? = nil
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18, height: 18)
            Text(title).foregroundStyle(state == .pending ? .secondary : .primary)
            Spacer()
            if let detail { Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: StatusLevel.great.symbol).foregroundStyle(.green)
        case .warning: Image(systemName: StatusLevel.fair.symbol).foregroundStyle(.orange)
        case .failed: Image(systemName: StatusLevel.poor.symbol).foregroundStyle(.red)
        case .info: Image(systemName: StatusLevel.info.symbol).foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - ChannelChart

struct ChannelScore: Identifiable, Sendable {
    let channel: Int
    let score: Double
    var isDFS = false
    var id: Int { channel }
}

struct ChannelChart: View {
    let channels: [ChannelScore]
    let current: Int
    let recommended: Int

    var body: some View {
        Chart(channels) { item in
            BarMark(
                x: .value("Canale", String(item.channel)),
                y: .value("Affollamento", max(item.score, 0.04))   // le barre libere restano visibili
            )
            .foregroundStyle(color(item.score))
            .cornerRadius(4)
            .annotation(position: .top, spacing: 2) {
                if item.channel == current {
                    Image(systemName: "arrowtriangle.down.fill").font(.caption2)
                } else if item.channel == recommended {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.green)
                }
            }
            .accessibilityLabel("Canale \(item.channel)")
            .accessibilityValue(Thresholds.channelLoadWord(item.score))
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1.25)
        .frame(height: 190)
    }

    private func color(_ s: Double) -> Color {
        s > 0.9 ? .red : s > 0.6 ? .orange : s >= 0.3 ? .yellow : .green
    }
}

// MARK: - LatencyChart

struct LatencySample: Identifiable, Sendable {
    let date: Date
    let ms: Double
    var id: Date { date }
}

struct LatencyChart: View {
    let samples: [LatencySample]
    var goodBelow: Double = 10   // zona "Ottimo" evidenziata

    var body: some View {
        Chart {
            RectangleMark(yStart: .value("min", 0), yEnd: .value("max", goodBelow))
                .foregroundStyle(.green.opacity(0.07))
            ForEach(samples) { s in
                AreaMark(x: .value("Ora", s.date), y: .value("ms", s.ms))
                    .foregroundStyle(Color.accentColor.opacity(0.2))
                LineMark(x: .value("Ora", s.date), y: .value("ms", s.ms))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxisLabel("ms")
        .frame(height: 170)
    }
}

// MARK: - EmptyState (wrapper di ContentUnavailableView)

struct EmptyStateCard: View {
    let title: String
    let symbol: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Anteprime

#Preview("Componenti") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack { ForEach([StatusLevel.great, .good, .fair, .poor, .info], id: \.self) { StatusBadge(level: $0) } }
            HStack(spacing: 20) { HealthGauge(score: 76, level: .good); SignalBars(rssi: -54); TagChip(kind: .privateAddress) }
            HStack {
                MetricTile(title: "Segnale", value: "−54", unit: "dBm", level: Thresholds.rssi(-54))
                MetricTile(title: "Canale", value: "Saturo", level: Thresholds.channelLoad(1.16), badge: "Ch 36", raw: "punteggio 1,16")
            }
            SectionCard("Cosa puoi migliorare", symbol: "wand.and.stars") {
                InsightRow(level: .fair, title: "Sposta il 5 GHz dal canale 36 al 52",
                           detail: "Un router vicino usa il tuo stesso canale.", actionTitle: "Come si fa")
            }
            ChannelChart(channels: [.init(channel: 36, score: 1.16), .init(channel: 40, score: 0.92),
                                    .init(channel: 44, score: 1.06), .init(channel: 48, score: 0.92),
                                    .init(channel: 52, score: 0, isDFS: true), .init(channel: 149, score: 0.87)],
                         current: 36, recommended: 52)
        }
        .padding(24)
    }
    .frame(width: 760, height: 760)
}
