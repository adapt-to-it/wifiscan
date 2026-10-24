import Foundation
import Network

/// Risultato di port scan: porte aperte con label del servizio noto.
public struct PortScanResult: Sendable, Hashable {
    public let port: Int
    public let serviceName: String   // es. "ssh", "http", "smb"
}

/// Esegue TCP connect su un set di porte comuni per scoprire servizi esposti.
public final class PortScanner: @unchecked Sendable {
    /// Porte comuni con nome servizio.
    public static let commonPorts: [(port: Int, name: String)] = [
        (22, "ssh"),
        (53, "dns"),
        (80, "http"),
        (139, "netbios"),
        (143, "imap"),
        (443, "https"),
        (445, "smb"),
        (548, "afp"),
        (554, "rtsp"),
        (631, "ipp"),
        (993, "imaps"),
        (1883, "mqtt"),
        (3000, "http-dev"),
        (3306, "mysql"),
        (3389, "rdp"),
        (5000, "upnp/synology"),
        (5432, "postgres"),
        (5900, "vnc"),
        (6379, "redis"),
        (7000, "rao p/airplay"),
        (8006, "proxmox"),
        (8080, "http-alt"),
        (8123, "homeassistant"),
        (8443, "https-alt"),
        (8888, "http-alt"),
        (9000, "portainer"),
        (9100, "printer-raw"),
        (32400, "plex"),
    ]

    public init() {}

    /// Scansiona le porte standard su `host` (IP o hostname). Timeout per porta: `timeout`.
    /// Concorrenza limitata a `concurrency` parallele.
    public func scan(host: String,
                     ports: [(port: Int, name: String)] = PortScanner.commonPorts,
                     timeout: TimeInterval = 0.6,
                     concurrency: Int = 8) async -> [PortScanResult] {
        let total = ports.count
        let resultActor = ResultsActor()

        await withTaskGroup(of: Void.self) { group in
            var iterator = ports.makeIterator()
            var inFlight = 0
            for _ in 0..<min(concurrency, total) {
                guard let p = iterator.next() else { break }
                group.addTask { [self] in
                    if await self.isOpen(host: host, port: p.port, timeout: timeout) {
                        await resultActor.add(PortScanResult(port: p.port, serviceName: p.name))
                    }
                }
                inFlight += 1
            }
            while await group.next() != nil {
                if let p = iterator.next() {
                    group.addTask { [self] in
                        if await self.isOpen(host: host, port: p.port, timeout: timeout) {
                            await resultActor.add(PortScanResult(port: p.port, serviceName: p.name))
                        }
                    }
                }
            }
        }

        return await resultActor.snapshot().sorted { $0.port < $1.port }
    }

    /// True se la porta TCP è raggiungibile su host entro timeout.
    private func isOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Self.tryConnect(host: host, port: port)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func tryConnect(host: String, port: Int) async -> Bool {
        let guardActor = OnceBoolGuard()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let h = NWEndpoint.Host(host)
            guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else {
                cont.resume(returning: false); return
            }
            let conn = NWConnection(host: h, port: p, using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { await guardActor.tryResume(cont, value: true); conn.cancel() }
                case .failed, .cancelled:
                    Task { await guardActor.tryResume(cont, value: false) }
                case .waiting:
                    // host irraggiungibile, niente porta TCP che accetta → considera chiusa
                    Task { await guardActor.tryResume(cont, value: false); conn.cancel() }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }
}

private actor ResultsActor {
    private var results: [PortScanResult] = []
    func add(_ r: PortScanResult) { results.append(r) }
    func snapshot() -> [PortScanResult] { results }
}

private actor OnceBoolGuard {
    private var resumed = false
    func tryResume(_ cont: CheckedContinuation<Bool, Never>, value: Bool) {
        if resumed { return }
        resumed = true
        cont.resume(returning: value)
    }
}
