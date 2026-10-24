import Foundation
import Darwin

/// Ping sweep ICMP in-process su un unico socket `SOCK_DGRAM` (non richiede root su macOS).
/// Invia tutti gli echo request in sequenza e raccoglie le risposte in parallelo:
/// la durata dipende dal timeout, non dal numero di host.
public final class PingSweep: @unchecked Sendable {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 0.8) {
        self.timeout = timeout
    }

    /// Pinga tutti gli IP e restituisce quelli che hanno risposto.
    /// `progress` riceve (completati, totali) durante lo sweep.
    public func sweep(addresses: [String],
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Set<String> {
        await withCheckedContinuation { cont in
            // Thread GCD dedicato: poll() blocca, quindi resta fuori dal pool cooperativo.
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.icmpSweep(addresses, progress: progress))
            }
        }
    }

    /// Ping singolo.
    public func pingOneShot(ip: String) async -> Bool {
        await sweep(addresses: [ip]).contains(ip)
    }

    private func icmpSweep(_ addresses: [String],
                           progress: (@Sendable (Int, Int) -> Void)?) -> Set<String> {
        let total = addresses.count
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0, total > 0 else { return [] }
        defer { close(fd) }
        var rcvBuf: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        var targets: [in_addr_t: String] = [:]
        for ip in addresses {
            var a = in_addr()
            if inet_pton(AF_INET, ip, &a) == 1 { targets[a.s_addr] = ip }
        }
        let ident = UInt16(truncatingIfNeeded: getpid())
        var alive = Set<String>()

        // Due round: il secondo ripete solo verso chi non ha risposto (ARP lento, pacchetti persi).
        for round in 0..<2 {
            let pending = targets.filter { !alive.contains($0.value) }
            for (i, addr) in pending.keys.enumerated() {
                Self.sendEcho(fd: fd, to: addr, ident: ident, seq: UInt16(round))
                if i % 16 == 15 { Self.drain(fd: fd, targets: targets, into: &alive) }
                usleep(100)  // evita di saturare la coda ARP del kernel
            }
            let wait = round == 0 ? timeout : timeout / 2
            let deadline = Date().addingTimeInterval(wait)
            var left = wait
            while left > 0 {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, Int32(left * 1000) + 1) > 0 {
                    Self.drain(fd: fd, targets: targets, into: &alive)
                }
                left = deadline.timeIntervalSinceNow
            }
            progress?(round == 0 ? total / 2 : total, total)
        }
        return alive
    }

    static func sendEcho(fd: Int32, to addr: in_addr_t, ident: UInt16, seq: UInt16) {
        // Header ICMP echo (8 byte) + 8 byte di payload.
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8  // echo request
        packet[4] = UInt8(ident >> 8); packet[5] = UInt8(ident & 0xFF)
        packet[6] = UInt8(seq >> 8);   packet[7] = UInt8(seq & 0xFF)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xFF)

        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_addr.s_addr = addr
        _ = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Legge tutte le risposte già arrivate senza bloccare.
    private static func drain(fd: Int32, targets: [in_addr_t: String], into alive: inout Set<String>) {
        var buf = [UInt8](repeating: 0, count: 1500)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buf, buf.count, MSG_DONTWAIT, $0, &len)
                }
            }
            guard n > 0 else { return }
            // Su macOS il socket DGRAM ICMP consegna anche l'header IP: lo saltiamo.
            let off = buf[0] >> 4 == 4 ? Int(buf[0] & 0x0F) * 4 : 0
            guard n >= off + 8, buf[off] == 0 else { continue }  // 0 = echo reply
            if let ip = targets[from.sin_addr.s_addr] { alive.insert(ip) }
        }
    }

    /// Ident e seq di un echo reply in `buf` (nil se non è un echo reply valido). `n` > 0.
    static func echoReplyIdentSeq(_ buf: [UInt8], count n: Int) -> (ident: UInt16, seq: UInt16)? {
        let off = buf[0] >> 4 == 4 ? Int(buf[0] & 0x0F) * 4 : 0
        guard n >= off + 8, buf[off] == 0 else { return nil }  // 0 = echo reply
        let ident = UInt16(buf[off + 4]) << 8 | UInt16(buf[off + 5])
        let seq = UInt16(buf[off + 6]) << 8 | UInt16(buf[off + 7])
        return (ident, seq)
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: data.count - 1, by: 2) {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
