import Foundation
import SystemConfiguration

/// Latenza DNS per resolver su nome casuale (N2).
public enum DNSProber {
    /// Resolver di sistema, in ordine, da SystemConfiguration (State:/Network/Global/DNS).
    public static func systemResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "wifiscan.dns" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString),
              let dict = value as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String]
        else { return [] }
        return servers.filter { isIPv4($0) }
    }

    /// Tempo di risposta in ms di `resolver` (IPv4) a una query A su un nome casuale; nil = nessuna risposta.
    public static func measure(resolver: String, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: blockingMeasure(resolver: resolver, timeout: timeout))
            }
        }
    }

    /// Pacchetto di query DNS: tipo A, classe IN, ricorsione richiesta.
    static func buildQuery(id: UInt16, name: String) -> [UInt8] {
        var out: [UInt8] = [
            UInt8(id >> 8), UInt8(id & 0xFF), // id, big-endian
            0x01, 0x00,                       // flags: RD
            0x00, 0x01,                       // QDCOUNT
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // ANCOUNT, NSCOUNT, ARCOUNT
        ]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            out.append(UInt8(bytes.count))
            out += bytes
        }
        out.append(0)
        out += [0x00, 0x01, 0x00, 0x01] // QTYPE A, QCLASS IN
        return out
    }

    /// true se `packet` è una risposta (bit QR) con lo stesso id, qualunque sia il codice di risposta.
    static func isResponse(_ packet: [UInt8], id: UInt16) -> Bool {
        guard packet.count >= 12 else { return false }
        let packetID = (UInt16(packet[0]) << 8) | UInt16(packet[1])
        return packetID == id && (packet[2] & 0x80) != 0
    }

    private static func isIPv4(_ address: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, address, &addr) == 1
    }

    /// Invio e attesa bloccanti; eseguito fuori dal cooperative pool.
    private static func blockingMeasure(resolver: String, timeout: TimeInterval) -> Double? {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, resolver, &target.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let id = UInt16.random(in: 0...UInt16.max)
        let query = buildQuery(id: id, name: randomProbeName() + ".wifiscan-probe.com")
        let address = target

        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start &+ UInt64(max(0, timeout) * 1_000_000_000)

        let sent = query.withUnsafeBytes { buf -> Int in
            withUnsafePointer(to: address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 1500)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return nil }
            let remainingMs = Int32(min(Double(deadline - now) / 1_000_000, Double(Int32.max)))

            let ready = poll(&pfd, 1, max(1, remainingMs))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0 else { continue }

            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let packet = Array(buffer[0..<Int(n)])
            if isResponse(packet, id: id) {
                let end = DispatchTime.now().uptimeNanoseconds
                return Double(end - start) / 1_000_000
            }
        }
    }

    /// Etichetta casuale di 12 caratteri a-z0-9, per evitare la cache del resolver.
    private static func randomProbeName() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in alphabet.randomElement() ?? "a" })
    }
}
