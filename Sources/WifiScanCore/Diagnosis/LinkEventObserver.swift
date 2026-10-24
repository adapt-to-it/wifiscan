import CoreWLAN
import Foundation

/// Eventi di collegamento N16 da CWEventDelegate.
public final class LinkEventObserver: NSObject, @unchecked Sendable {
    private let onEvent: @Sendable (LinkEvent) -> Void
    private let client = CWWiFiClient.shared()

    public init(onEvent: @escaping @Sendable (LinkEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    public func start() {
        client.delegate = self
        try? client.startMonitoringEvent(with: .linkDidChange)
        try? client.startMonitoringEvent(with: .bssidDidChange)
    }

    public func stop() {
        try? client.stopMonitoringAllEvents()
    }
}

extension LinkEventObserver: CWEventDelegate {
    public func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        let interface = client.interface(withName: interfaceName)
        let connected = interface?.ssid() != nil || interface?.bssid() != nil
        onEvent(LinkEvent(t: Date(), kind: connected ? .linkUp : .linkDown, bssid: nil))
    }

    public func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        let bssid = client.interface(withName: interfaceName)?.bssid()
        onEvent(LinkEvent(t: Date(), kind: .bssidChanged, bssid: bssid))
    }
}
