import Foundation

/// Risultato di un singolo ping (RTT in millisecondi).
public struct PingSample: Sendable, Hashable {
    public let rttMillis: Double?    // nil = timeout
    public let timestamp: Date
}

/// Statistiche aggregate.
public struct PingStats: Sendable {
    public let sent: Int
    public let received: Int
    public let minMs: Double?
    public let avgMs: Double?
    public let maxMs: Double?
    public let jitterMs: Double?     // deviazione standard
    public let lossPercent: Double

    public init(samples: [PingSample]) {
        let total = samples.count
        let ok = samples.compactMap(\.rttMillis)
        self.sent = total
        self.received = ok.count
        self.lossPercent = total == 0 ? 0 : (1.0 - Double(ok.count) / Double(total)) * 100
        self.minMs = ok.min()
        self.maxMs = ok.max()
        if ok.isEmpty {
            self.avgMs = nil; self.jitterMs = nil
        } else {
            let avg = ok.reduce(0, +) / Double(ok.count)
            self.avgMs = avg
            if ok.count > 1 {
                let variance = ok.map { pow($0 - avg, 2) }.reduce(0, +) / Double(ok.count)
                self.jitterMs = variance.squareRoot()
            } else {
                self.jitterMs = 0
            }
        }
    }
}

/// Esegue ping ICMP via /sbin/ping. Single-host con misurazione RTT.
public final class Pinger: @unchecked Sendable {

    public init() {}

    /// Esegue N ping consecutivi al `host`. Restituisce sample list.
    public func ping(host: String, count: Int = 5, timeout: TimeInterval = 1.0) async -> [PingSample] {
        var samples: [PingSample] = []
        for _ in 0..<count {
            let s = await singlePing(host: host, timeout: timeout)
            samples.append(s)
        }
        return samples
    }

    /// Eseguito 1 ping. Restituisce sample con RTT in ms (nil se timeout/error).
    public func singlePing(host: String, timeout: TimeInterval = 1.0) async -> PingSample {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
            proc.arguments = ["-c", "1", "-W", "\(Int(timeout * 1000))", "-n", "-q", host]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            let now = Date()
            do {
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    return PingSample(rttMillis: nil, timestamp: now)
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                // riga finale: "round-trip min/avg/max/stddev = 1.234/1.234/1.234/0.000 ms"
                if let r = out.range(of: "= "),
                   let end = out.range(of: " ms", range: r.upperBound..<out.endIndex) {
                    let stats = out[r.upperBound..<end.lowerBound]
                    let parts = stats.split(separator: "/")
                    if parts.count >= 2, let avg = Double(parts[1]) {
                        return PingSample(rttMillis: avg, timestamp: now)
                    }
                }
                return PingSample(rttMillis: nil, timestamp: now)
            } catch {
                return PingSample(rttMillis: nil, timestamp: now)
            }
        }.value
    }
}
