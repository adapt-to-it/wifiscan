import Foundation
import Darwin

/// Ping continuo con RTT (N1) su un solo socket ICMP SOCK_DGRAM, come PingSweep.
public final class ICMPProber: @unchecked Sendable {
    private let fd: Int32  // -1 se il socket non si apre: probe restituisce nil per tutti
    private let ident: UInt16
    private let queue = DispatchQueue(label: "wifiscan.icmp-prober")  // seriale: una chiamata alla volta
    private var seq: UInt16 = 0  // accesso solo dalla coda

    public init() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        ident = UInt16.random(in: 1...UInt16.max)
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Invia un echo a ciascun indirizzo IPv4 e attende le risposte fino a `timeout`.
    /// Restituisce l'RTT in ms per indirizzo; nil = timeout o indirizzo non valido.
    public func probe(_ addresses: [String], timeout: TimeInterval) async -> [String: Double?] {
        await withCheckedContinuation { cont in
            // Coda dedicata: recvfrom/poll bloccano, quindi restano fuori dal pool cooperativo.
            queue.async {
                cont.resume(returning: self.run(addresses, timeout: timeout))
            }
        }
    }

    private func run(_ addresses: [String], timeout: TimeInterval) -> [String: Double?] {
        var targets: [in_addr_t: String] = [:]
        for ip in addresses {
            var a = in_addr()
            if inet_pton(AF_INET, ip, &a) == 1 { targets[a.s_addr] = ip }
        }

        var rtts: [String: Double] = [:]
        if fd >= 0 && !targets.isEmpty {
            seq &+= 1
            let s = seq
            var sent: [in_addr_t: UInt64] = [:]
            for addr in targets.keys {
                sent[addr] = DispatchTime.now().uptimeNanoseconds
                PingSweep.sendEcho(fd: fd, to: addr, ident: ident, seq: s)
            }
            collect(seq: s, targets: targets, sent: sent, into: &rtts, timeout: timeout)
        }

        var out: [String: Double?] = [:]
        for ip in addresses { out[ip] = .some(rtts[ip]) }
        return out
    }

    /// Raccoglie le risposte a `s` fino a `timeout`; la prima risposta per indirizzo vince.
    private func collect(seq s: UInt16, targets: [in_addr_t: String], sent: [in_addr_t: UInt64],
                         into rtts: inout [String: Double], timeout: TimeInterval) {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, timeout) * 1_000_000_000)
        var buf = [UInt8](repeating: 0, count: 1500)
        while rtts.count < targets.count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32((deadline - now) / 1_000_000) + 1) > 0 else { continue }

            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buf, buf.count, MSG_DONTWAIT, $0, &len)
                    }
                }
                guard n > 0 else { break }
                let arrival = DispatchTime.now().uptimeNanoseconds
                // Su macOS il socket DGRAM ICMP consegna anche l'header IP: lo gestisce echoReplyIdentSeq.
                guard let reply = PingSweep.echoReplyIdentSeq(buf, count: n),
                      reply.ident == ident, reply.seq == s,
                      let ip = targets[from.sin_addr.s_addr],
                      rtts[ip] == nil,
                      let t0 = sent[from.sin_addr.s_addr] else { continue }
                rtts[ip] = Double(arrival - t0) / 1_000_000
            }
        }
    }
}
