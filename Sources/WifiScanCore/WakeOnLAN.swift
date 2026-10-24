import Foundation
import Network

/// Invia un magic packet Wake-on-LAN broadcast UDP 255.255.255.255:9.
public enum WakeOnLAN {
    /// Costruisce il magic packet (6 byte 0xFF + 16 ripetizioni MAC) e lo invia.
    /// Restituisce true se il packet è stato inviato (non garantisce wake).
    @discardableResult
    public static func wake(mac: String, port: UInt16 = 9) async -> Bool {
        guard let macBytes = parseMACBytes(mac), macBytes.count == 6 else { return false }

        var built = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { built.append(macBytes) }
        let packet = built   // copia immutabile per il closure capture

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let host = NWEndpoint.Host("255.255.255.255")
            guard let port = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: false); return
            }
            let params = NWParameters.udp
            if let opts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                _ = opts  // niente IP_PKTINFO; useremo broadcast standard
            }
            let conn = NWConnection(host: host, port: port, using: params)
            let guardActor = OnceBoolGuard()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: packet, completion: .contentProcessed { _ in
                        Task { await guardActor.tryResume(cont, value: true); conn.cancel() }
                    })
                case .failed, .cancelled:
                    Task { await guardActor.tryResume(cont, value: false) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            // Timeout fail-safe
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                conn.cancel()
                await guardActor.tryResume(cont, value: false)
            }
        }
    }

    private static func parseMACBytes(_ s: String) -> Data? {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 6 else { return nil }
        var data = Data()
        for p in parts {
            let padded = p.count == 1 ? "0\(p)" : p
            guard let byte = UInt8(padded, radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

private actor OnceBoolGuard {
    private var resumed = false
    func tryResume(_ cont: CheckedContinuation<Bool, Never>, value: Bool) {
        if resumed { return }
        resumed = true
        cont.resume(returning: value)
    }
}
