import SwiftUI
import WifiScanCore

enum Section: String, CaseIterable, Identifiable, Hashable {
    case overview = "Panoramica"
    case link = "Collegamento"
    case ghz24 = "2.4 GHz"
    case ghz5 = "5 GHz"
    case networks = "Reti vicine"
    case recommendations = "Raccomandazioni"
    case lan = "Dispositivi LAN"
    case diagnostics = "Diagnostica"
    case recording = "Registrazione"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .link:     "waveform.path.ecg"
        case .ghz24:    "antenna.radiowaves.left.and.right"
        case .ghz5:     "wifi"
        case .networks: "list.bullet.rectangle"
        case .recommendations: "checkmark.seal"
        case .lan:      "network"
        case .diagnostics: "stethoscope"
        case .recording:   "record.circle"
        }
    }
}

struct ContentView: View {
    @State private var selection: Section? = .overview
    @State private var vm = ScanViewModel()
    @State private var lanVm = LanScanViewModel()
    @State private var diagVm = DiagnosticsViewModel()
    @State private var linkVm = LinkViewModel()
    @State private var recordingVm = RecordingViewModel()
    @State private var locationAuth = LocationAuthorizationModel()
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                .navigationTitle("WiFi Scanner")
        } detail: {
            DetailRoot(section: selection ?? .overview, vm: vm, lanVm: lanVm, diagVm: diagVm,
                       linkVm: linkVm, recordingVm: recordingVm, locationAuth: locationAuth)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showSettings.toggle()
                        } label: {
                            Label("Impostazioni", systemImage: "gearshape")
                        }
                        .help("Impostazioni")

                        Button {
                            Task { await vm.scan() }
                        } label: {
                            Label("Scansiona", systemImage: vm.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(vm.isScanning)
                        .help("Esegui una nuova scansione (⌘R)")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(vm: vm, locationAuth: locationAuth)
        }
        .task {
            locationAuth.requestIfNeeded()
            await vm.scan()
        }
        .onChange(of: locationAuth.isAuthorized) { _, newValue in
            // Appena l'utente concede Location, gli SSID diventano disponibili: ri-scansiona.
            if newValue {
                Task { await vm.scan() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerScan)) { _ in
            Task { await vm.scan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appWillTerminate)) { _ in
            vm.cancelScan()
            lanVm.cancelScan()
            diagVm.cancelAll()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: Section?

    var body: some View {
        List(Section.allCases, selection: $selection) { section in
            NavigationLink(value: section) {
                Label(section.rawValue, systemImage: section.systemImage)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Detail Router

struct DetailRoot: View {
    let section: Section
    let vm: ScanViewModel
    let lanVm: LanScanViewModel
    let diagVm: DiagnosticsViewModel
    let linkVm: LinkViewModel
    let recordingVm: RecordingViewModel
    let locationAuth: LocationAuthorizationModel

    var body: some View {
        VStack(spacing: 0) {
            if !locationAuth.isAuthorized {
                LocationBanner(locationAuth: locationAuth)
            }
            Group {
                switch section {
                case .overview:        OverviewView(vm: vm)
                case .link:            LinkView(vm: linkVm)
                case .ghz24:           BandView(vm: vm, band: .ghz24)
                case .ghz5:            BandView(vm: vm, band: .ghz5)
                case .networks:        NetworksView(vm: vm)
                case .recommendations: RecommendationsView(vm: vm)
                case .lan:             LanDevicesView(vm: lanVm)
                case .diagnostics:     DiagnosticsView(vm: diagVm)
                case .recording:       RecordingView(vm: recordingVm, locationAuthorized: locationAuth.isAuthorized)
                }
            }
        }
        .navigationTitle(section.rawValue)
        .navigationSubtitle(subtitleForCurrentScan)
    }

    private var subtitleForCurrentScan: String {
        if section == .lan {
            if lanVm.isScanning {
                return "\(lanVm.devicesList.count) dispositivi finora…"
            }
            if lanVm.devicesList.isEmpty {
                return "Nessuna scansione LAN"
            }
            return "\(lanVm.devicesList.count) dispositivi · scan in \(String(format: "%.1f", lanVm.elapsed))s"
        }
        if section == .diagnostics {
            if let ip = diagVm.publicInfo?.ip { return "IP pubblico: \(ip)" }
            return "Diagnostica internet e LAN"
        }
        guard let r = vm.lastResult else { return "Nessuna scansione" }
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .medium
        return "\(r.networks.count) reti · ultimo scan \(df.string(from: r.timestamp))"
    }
}

// MARK: - Banner Location

struct LocationBanner: View {
    let locationAuth: LocationAuthorizationModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: locationAuth.isDenied ? "location.slash.fill" : "location.circle.fill")
                .foregroundStyle(locationAuth.isDenied ? Color.orange : Color.accentColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(locationAuth.isDenied
                     ? "Permesso Localizzazione negato"
                     : "Per vedere i nomi delle reti")
                .font(.callout.weight(.semibold))
                Text(locationAuth.isDenied
                     ? "macOS richiede questo permesso per rivelare gli SSID delle reti vicine. Riabilitalo in Impostazioni di Sistema."
                     : "macOS richiede il permesso di localizzazione per accedere ai nomi delle reti Wi-Fi vicine.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if locationAuth.isDenied {
                Button("Apri Impostazioni") {
                    locationAuth.openSystemSettings()
                }
                .controlSize(.regular)
            } else if locationAuth.isPending {
                Button("Consenti…") {
                    locationAuth.requestIfNeeded()
                }
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            (locationAuth.isDenied ? Color.orange : Color.accentColor)
                .opacity(0.08)
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    let vm: ScanViewModel
    let locationAuth: LocationAuthorizationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Impostazioni").font(.title2.bold())
                Spacer()
                Button("Fine") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Divider()

            // Sezione Privacy / Location
            VStack(alignment: .leading, spacing: 10) {
                Label("Privacy", systemImage: "lock.shield")
                    .font(.headline)
                HStack(spacing: 12) {
                    Circle()
                        .fill(locationAuth.isAuthorized ? Color.green : (locationAuth.isDenied ? Color.orange : Color.secondary))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Localizzazione: \(locationAuth.statusDescription)")
                            .font(.callout.weight(.medium))
                        Text(locationAuth.isAuthorized
                             ? "Gli SSID delle reti vicine vengono mostrati."
                             : "macOS nasconde gli SSID delle reti senza questo permesso.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if locationAuth.isPending {
                        Button("Richiedi") { locationAuth.requestIfNeeded() }
                    } else if locationAuth.isDenied {
                        Button("Impostazioni") { locationAuth.openSystemSettings() }
                    }
                }
            }

            Divider()

            // Override manuali
            VStack(alignment: .leading, spacing: 10) {
                Label("Override identificazione rete propria", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.headline)
                Text("Se la Localizzazione non è attiva e gli SSID sono nascosti, puoi indicare manualmente la tua rete per escluderla dallo scoring.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("SSID").foregroundStyle(.secondary)
                        TextField("es. HS_5G", text: Binding(
                            get: { vm.overrideSsid },
                            set: { vm.overrideSsid = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Canale").foregroundStyle(.secondary)
                        TextField("es. 44", text: Binding(
                            get: { vm.overrideChannel },
                            set: { vm.overrideChannel = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120, alignment: .leading)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Label("Interfaccia", systemImage: "wifi.router")
                    .font(.headline)
                Text(vm.interfaceLabel)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 520, height: 480)
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 700)
}
