import SwiftUI
import AppKit
import WifiScanCore

@MainActor
final class RecordingViewModel: ObservableObject {
    /// Etichette fisse (DIAGNOSI.md 12.5).
    static let etichette = [
        "rete-sana", "lontano-dal-router", "exit-node", "failover-lte", "degrado-simulato",
        "canale-affollato", "awdl", "ethernet", "dns-lento", "time-machine",
    ]

    struct Conteggi: Equatable {
        var probe = 0
        var link = 0
        var dns = 0
        var eventi = 0
        var testSottoCarico = 0
    }

    let monitor = DiagnosisMonitor()

    @Published var isRunning = false
    @Published var elapsed: TimeInterval = 0
    @Published var counts = Conteggi()
    /// Percentuale di probe persi sugli ultimi 120 non contaminati; nil se non ci sono campioni.
    @Published var lossGateway: Double?
    @Published var lossInternet: Double?
    @Published var loadTesting = false
    @Published var saved: [URL] = []
    @Published var lastError: String?
    @Published var labels: Set<String> = []
    @Published var note = ""

    private var pollTask: Task<Void, Never>?

    init() { refreshSaved() }

    func start(locationAuthorized: Bool) {
        guard !isRunning else { return }
        lastError = nil
        isRunning = true
        Task {
            await self.monitor.start(locationAuthorized: locationAuthorized)
            self.startPolling()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        let labels = self.labels.sorted()
        let note = self.note
        Task {
            guard var session = await self.monitor.stop() else { return }
            session.meta.labels = labels
            session.meta.note = note
            self.apply(session)
            do {
                _ = try SessionRecorder.save(session)
                // Ogni sessione descrive uno scenario: le etichette non passano alla successiva.
                self.labels = []
                self.note = ""
            } catch {
                self.lastError = "Salvataggio non riuscito: \(error.localizedDescription)"
            }
            self.refreshSaved()
        }
    }

    func runLoadTest() {
        guard isRunning, !loadTesting else { return }
        loadTesting = true
        Task {
            let record = await self.monitor.runLoadTest()
            self.loadTesting = false
            if record == nil {
                self.lastError = "Test sotto carico non riuscito"
            }
        }
    }

    func refreshSaved() {
        saved = SessionRecorder.list()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let vm = self, vm.isRunning, !Task.isCancelled {
                if let session = await vm.monitor.current() {
                    vm.apply(session)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func apply(_ session: DiagnosisSession) {
        elapsed = max(0, (session.meta.end ?? Date()).timeIntervalSince(session.meta.start))
        counts = Conteggi(probe: session.probes.count,
                          link: session.link.count,
                          dns: session.dns.count,
                          eventi: session.events.count,
                          testSottoCarico: session.loadTests.count)
        lossGateway = lossPercent(session.probes, targets: [.gateway])
        lossInternet = lossPercent(session.probes, targets: [.cloudflare, .google])
    }

    private func lossPercent(_ probes: [ProbeSample], targets: Set<ProbeTarget>) -> Double? {
        let ultimi = probes.filter { targets.contains($0.target) && !$0.contaminated }.suffix(120)
        guard !ultimi.isEmpty else { return nil }
        let persi = ultimi.filter { $0.rttMs == nil }.count
        return Double(persi) / Double(ultimi.count) * 100
    }
}

struct RecordingView: View {
    @ObservedObject var vm: RecordingViewModel
    /// Passato a vm.start alla registrazione.
    let locationAuthorized: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                recordingCard
                loadTestCard
                labelsCard
                savedCard
            }
            .padding()
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Registrazione sessione").font(.headline)
            HStack {
                Text(elapsedText)
                    .font(.title.monospacedDigit())
                Spacer()
                Button(vm.isRunning ? "Ferma" : "Avvia") {
                    if vm.isRunning {
                        vm.stop()
                    } else {
                        vm.start(locationAuthorized: locationAuthorized)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("Probe", "\(vm.counts.probe)")
                row("Collegamento", "\(vm.counts.link)")
                row("DNS", "\(vm.counts.dns)")
                row("Eventi", "\(vm.counts.eventi)")
                row("Test sotto carico", "\(vm.counts.testSottoCarico)")
                row("Perdita gateway (ultimi 120)", percentText(vm.lossGateway))
                row("Perdita internet (ultimi 120)", percentText(vm.lossInternet))
            }
        }
        .recordingCardStyle()
    }

    private var loadTestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test sotto carico").font(.headline)
            Button("Avvia test sotto carico") {
                vm.runLoadTest()
            }
            .disabled(!vm.isRunning || vm.loadTesting)
            if vm.loadTesting {
                ProgressView("Test in corso…")
            }
        }
        .recordingCardStyle()
    }

    private var labelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Etichette").font(.headline)
            ForEach(RecordingViewModel.etichette, id: \.self) { label in
                Toggle(label, isOn: labelBinding(label))
            }
            TextField("Nota", text: $vm.note)
        }
        .recordingCardStyle()
    }

    private var savedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessioni salvate").font(.headline)
            if vm.saved.isEmpty {
                Text("Nessuna sessione salvata")
                    .foregroundStyle(.secondary)
            }
            ForEach(vm.saved, id: \.self) { url in
                Text(url.lastPathComponent)
                    .font(.callout.monospaced())
            }
            Button("Mostra nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(vm.saved)
            }
            .disabled(vm.saved.isEmpty)
            if let error = vm.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .recordingCardStyle()
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private var elapsedText: String {
        let total = Int(vm.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + " %"
    }

    private func labelBinding(_ label: String) -> Binding<Bool> {
        Binding(
            get: { vm.labels.contains(label) },
            set: { isOn in
                if isOn {
                    vm.labels.insert(label)
                } else {
                    vm.labels.remove(label)
                }
            }
        )
    }
}

private extension View {
    /// Stesso stile di linkCardStyle (@stile-card): padding 20, sfondo arrotondato.
    func recordingCardStyle() -> some View {
        self.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
    }
}
