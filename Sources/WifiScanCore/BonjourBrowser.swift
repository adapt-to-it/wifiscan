import Foundation
import Network
import Darwin
import os.log

private let logger = Logger(subsystem: "com.marcoabbattista.wifiscanner", category: "Bonjour")

/// Servizio Bonjour scoperto.
public struct BonjourService: Sendable, Hashable {
    public let name: String       // es. "Apple-TV"
    public let serviceType: String  // es. "_airplay._tcp"
    public let domain: String     // es. "local."
    public let hostname: String?  // es. "Apple-TV.local."
    public let port: Int?
    public let ipv4: String?
}

/// Browser di servizi Bonjour comuni per identificare device sulla LAN.
public final class BonjourBrowser: @unchecked Sendable {
    public static let commonServices: [String] = [
        "_http._tcp",
        "_https._tcp",
        "_ssh._tcp",
        "_ipp._tcp",
        "_ipps._tcp",
        "_printer._tcp",
        "_pdl-datastream._tcp",
        "_smb._tcp",
        "_afpovertcp._tcp",
        "_nfs._tcp",
        "_airplay._tcp",
        "_raop._tcp",
        "_googlecast._tcp",
        "_hap._tcp",
        "_companion-link._tcp",
        "_device-info._tcp",
        "_apple-mobdev2._tcp",
        "_workstation._tcp",
        "_rdlink._tcp",
        "_sftp-ssh._tcp",
    ]

    public init() {}

    public func discover(duration: TimeInterval = 3.0) async -> [BonjourService] {
        let collector = ServiceCollector()
        var browsers: [NWBrowser] = []

        for serviceType in Self.commonServices {
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                using: .tcp
            )
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    if case let .service(name, type, domain, _) = r.endpoint {
                        let svc = BonjourService(
                            name: name,
                            serviceType: type,
                            domain: domain,
                            hostname: nil,
                            port: nil,
                            ipv4: nil
                        )
                        Task { await collector.add(svc) }
                    }
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            browsers.append(browser)
        }

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        for b in browsers { b.cancel() }

        let raw = await collector.snapshot()
        logger.info("Bonjour browse complete: \(raw.count, privacy: .public) services")

        // Resolve ogni servizio in parallelo via NWConnection con viabilityUpdateHandler.
        return await withTaskGroup(of: BonjourService.self, returning: [BonjourService].self) { group in
            for svc in raw {
                group.addTask {
                    let resolved = await Self.resolveViaConnection(name: svc.name, serviceType: svc.serviceType, domain: svc.domain)
                    return BonjourService(
                        name: svc.name,
                        serviceType: svc.serviceType,
                        domain: svc.domain,
                        hostname: resolved.hostname,
                        port: resolved.port,
                        ipv4: resolved.ipv4
                    )
                }
            }
            var results: [BonjourService] = []
            for await s in group { results.append(s) }
            let resolvedCount = results.filter { $0.ipv4 != nil }.count
            logger.info("Resolved \(resolvedCount, privacy: .public)/\(results.count, privacy: .public) services with IPv4")
            return results
        }
    }

    /// Resolve via NWConnection con timeout. Ascolta `viabilityUpdateHandler` invece di
    /// state, perché la connection è viable appena il path è risolto, anche prima del
    /// TCP handshake completo.
    private static func resolveViaConnection(name: String, serviceType: String, domain: String)
    async -> (hostname: String?, ipv4: String?, port: Int?) {
        let guardActor = ResolveGuard()
        let endpoint = NWEndpoint.service(name: name, type: serviceType, domain: domain, interface: nil)

        // Strategia: usiamo parameters TCP con preferEnableNoMetadata.
        let params = NWParameters.tcp
        params.preferNoProxies = true
        let conn = NWConnection(to: endpoint, using: params)

        return await withTaskGroup(of: (String?, String?, Int?)?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<(String?, String?, Int?), Never>) in
                    conn.pathUpdateHandler = { path in
                        // Path aggiornato: estrai endpoint risolto
                        if let remote = path.remoteEndpoint {
                            Task {
                                await guardActor.tryResume(cont, value: Self.extractFromEndpoint(remote))
                                conn.cancel()
                            }
                        }
                    }
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready, .preparing:
                            // Se il path è disponibile anche durante preparing, sfrutta.
                            if let path = conn.currentPath, let remote = path.remoteEndpoint {
                                Task {
                                    await guardActor.tryResume(cont, value: Self.extractFromEndpoint(remote))
                                    conn.cancel()
                                }
                            }
                        case .failed, .cancelled:
                            Task {
                                await guardActor.tryResume(cont, value: (nil, nil, nil))
                            }
                        default:
                            break
                        }
                    }
                    conn.start(queue: .global(qos: .userInitiated))
                }
            }

            // Timeout fail-safe
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }

            // Race
            let first = await group.next() ?? nil
            group.cancelAll()
            conn.cancel()
            return first ?? (nil, nil, nil)
        }
    }

    private static func extractFromEndpoint(_ endpoint: NWEndpoint) -> (String?, String?, Int?) {
        if case let .hostPort(host, port) = endpoint {
            switch host {
            case .ipv4(let addr):
                return (nil, "\(addr)", Int(port.rawValue))
            case .ipv6:
                return (nil, nil, Int(port.rawValue))
            case .name(let name, _):
                return (name, nil, Int(port.rawValue))
            @unknown default:
                return (nil, nil, Int(port.rawValue))
            }
        }
        return (nil, nil, nil)
    }
}

private actor ServiceCollector {
    private var services: Set<BonjourService> = []
    func add(_ svc: BonjourService) { services.insert(svc) }
    func snapshot() -> [BonjourService] { Array(services) }
}

private actor ResolveGuard {
    private var resumed = false
    func tryResume(_ cont: CheckedContinuation<(String?, String?, Int?), Never>,
                   value: (String?, String?, Int?)) {
        if resumed { return }
        resumed = true
        cont.resume(returning: value)
    }
}
