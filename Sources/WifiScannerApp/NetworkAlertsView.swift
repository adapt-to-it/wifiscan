import SwiftUI
import WifiScanCore

/// Elenco degli allarmi di rete; non occupa spazio se non ci sono allarmi da mostrare.
/// Gli allarmi "nuovo dispositivo" confluiscono in un gruppo compresso, e ogni allarme si può ignorare.
struct NetworkAlertsView: View {
    let alerts: [NetworkAlert]
    @State private var dismissed: Set<String> = []
    @State private var newDevicesExpanded = false

    private var visible: [NetworkAlert] { alerts.filter { !dismissed.contains($0.id) } }
    private var important: [NetworkAlert] { visible.filter { $0.kind != .newDevice } }
    private var newDevices: [NetworkAlert] { visible.filter { $0.kind == .newDevice } }

    var body: some View {
        if visible.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Avvisi").font(.headline)
                    Spacer()
                    Button("Ignora tutti") { dismissed.formUnion(visible.map(\.id)) }
                        .buttonStyle(.borderless)
                }
                ForEach(important) { alert in
                    AlertRow(alert: alert) { dismissed.insert(alert.id) }
                }
                if !newDevices.isEmpty {
                    DisclosureGroup(isExpanded: $newDevicesExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(newDevices) { alert in
                                AlertRow(alert: alert) { dismissed.insert(alert.id) }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: NetworkAlert.Severity.info.symbolName)
                                .foregroundStyle(NetworkAlert.Severity.info.tint)
                            Text(newDevices.count == 1 ? "1 nuovo dispositivo sulla rete"
                                                       : "\(newDevices.count) nuovi dispositivi sulla rete")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Ignora") { dismissed.formUnion(newDevices.map(\.id)) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        }
    }
}

private struct AlertRow: View {
    let alert: NetworkAlert
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.severity.symbolName)
                .foregroundStyle(alert.severity.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.subheadline.weight(.semibold))
                Text(alert.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Ignora questo avviso")
        }
    }
}

private extension NetworkAlert.Severity {
    var symbolName: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
