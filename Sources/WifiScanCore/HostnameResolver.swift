import Foundation
import Darwin

/// Reverse DNS via getnameinfo. Funziona per IP che hanno un record PTR
/// (.local via mDNS oppure DNS standard).
public enum HostnameResolver {
    /// Risolve un singolo IP → hostname. Restituisce nil se non risolvibile.
    /// `getnameinfo` è bloccante e senza timeout: gira su GCD, fuori dal pool cooperativo,
    /// e dopo `timeout` secondi restituiamo nil senza aspettarlo.
    public static func resolve(ip: String, timeout: TimeInterval = 1.0) async -> String? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            DispatchQueue.global(qos: .userInitiated).async { once.resume(lookup(ip: ip)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    private static func lookup(ip: String) -> String? {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        guard ip.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &sin) { sinPtr in
            sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getnameinfo(saPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count),
                            nil, 0,
                            NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(cString: host)
        if name == ip || name.isEmpty { return nil }  // niente nome reale
        return name
    }

    /// Risolve in batch parallelo. Restituisce mappa IP → hostname per ogni IP risolto.
    public static func resolveBatch(ips: [String], concurrency: Int = 20) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self, returning: [String: String].self) { group in
            var results: [String: String] = [:]
            var iterator = ips.makeIterator()
            var inFlight = 0

            func dispatchNext() {
                guard let ip = iterator.next() else { return }
                group.addTask {
                    let h = await Self.resolve(ip: ip)
                    return (ip, h)
                }
                inFlight += 1
            }

            for _ in 0..<min(concurrency, ips.count) { dispatchNext() }

            while let (ip, h) = await group.next() {
                if let h = h { results[ip] = h }
                dispatchNext()
            }
            return results
        }
    }
}

/// Riprende una continuation una sola volta: vince il primo tra risultato e timeout.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<String?, Never>?

    init(_ cont: CheckedContinuation<String?, Never>) { self.cont = cont }

    func resume(_ value: String?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
