import Foundation

/// Informazioni sulla connessione internet pubblica.
public struct PublicInternetInfo: Sendable {
    public let ip: String?
    public let city: String?
    public let region: String?
    public let country: String?
    public let isp: String?
    public let timestamp: Date
}

/// Risultato di uno speed test.
public struct SpeedTestResult: Sendable {
    public let bytesDownloaded: Int
    public let elapsedSeconds: Double
    public let timestamp: Date

    public var megabitsPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return (Double(bytesDownloaded) * 8.0) / (elapsedSeconds * 1_000_000.0)
    }
}

/// Servizi di diagnostica internet.
public enum DiagnosticsService {

    // MARK: - Public IP / ISP

    /// Recupera IP pubblico + dati geo/ISP via ipinfo.io (gratuito, no key, ~50k req/mese).
    /// Timeout 5s.
    public static func fetchPublicInfo() async -> PublicInternetInfo {
        let url = URL(string: "https://ipinfo.io/json")!
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return PublicInternetInfo(ip: nil, city: nil, region: nil, country: nil, isp: nil, timestamp: Date())
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return PublicInternetInfo(
                ip: json["ip"] as? String,
                city: json["city"] as? String,
                region: json["region"] as? String,
                country: json["country"] as? String,
                isp: json["org"] as? String,
                timestamp: Date()
            )
        } catch {
            return PublicInternetInfo(ip: nil, city: nil, region: nil, country: nil, isp: nil, timestamp: Date())
        }
    }

    // MARK: - Gateway

    /// Restituisce l'IP del gateway di default leggendo `netstat -rn`.
    public static func defaultGateway() async -> String? {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            proc.arguments = ["-rn", "-f", "inet"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                for line in out.split(separator: "\n") {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    // Con VPN/exit node la prima route di default è "link#N" sul tunnel: va saltata.
                    if cols.first == "default", cols.count >= 2, LocalSubnet.ipv4ToUInt32(cols[1]) != nil {
                        return cols[1]
                    }
                }
                return nil
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - Speed test

    /// Scarica un file di test e misura throughput. Default: 10 MB dal mirror Cloudflare.
    public static func runSpeedTest(
        url: URL = URL(string: "https://speed.cloudflare.com/__down?bytes=10485760")!,
        timeout: TimeInterval = 30
    ) async -> SpeedTestResult? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let elapsed = Date().timeIntervalSince(start)
            return SpeedTestResult(bytesDownloaded: data.count, elapsedSeconds: elapsed, timestamp: Date())
        } catch {
            return nil
        }
    }
}
