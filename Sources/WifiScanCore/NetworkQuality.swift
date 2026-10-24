import Foundation

/// Risultato di `/usr/bin/networkQuality -c`.
public struct NetworkQualityResult: Sendable {
    public let downloadMbps: Double
    public let uploadMbps: Double
    public let responsivenessRPM: Double
    public let baseRTTms: Double
    public let interfaceName: String?
    public let timestamp: Date
    /// RPM ≥ 800 "Alta", ≥ 300 "Media", altrimenti "Bassa" (bufferbloat).
    public var responsivenessLabel: String {
        if responsivenessRPM >= 800 { return "Alta" }
        if responsivenessRPM >= 300 { return "Media" }
        return "Bassa"
    }
}

public enum NetworkQualityRunner {
    /// Esegue `networkQuality -c -M <maxSeconds>` fuori dal pool cooperativo e ne legge lo stdout.
    public static func run(maxSeconds: Int = 20) async throws -> NetworkQualityResult {
        let (status, data) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, Data), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
                process.arguments = ["-c", "-M", String(maxSeconds)]
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, data))
            }
        }
        // Con -M un error_code 1003 è normale: se il JSON è utilizzabile il risultato vale comunque.
        if let result = try? parse(data) {
            return result
        }
        if status != 0 {
            throw NetworkQualityError.processFailed(status)
        }
        return try parse(data)
    }

    /// Converte il JSON di `networkQuality -c` (throughput in bit/s) in Mbit/s.
    public static func parse(_ json: Data) throws -> NetworkQualityResult {
        let raw = try JSONDecoder().decode(RawOutput.self, from: json)
        guard let download = raw.downloadThroughput else {
            throw NetworkQualityError.missingDownload
        }
        return NetworkQualityResult(
            downloadMbps: download / 1_000_000,
            uploadMbps: (raw.uploadThroughput ?? 0) / 1_000_000,
            responsivenessRPM: raw.responsiveness ?? 0,
            baseRTTms: raw.baseRTT ?? 0,
            interfaceName: raw.interfaceName,
            timestamp: Date()
        )
    }

    private struct RawOutput: Decodable {
        let downloadThroughput: Double?
        let uploadThroughput: Double?
        let responsiveness: Double?
        let baseRTT: Double?
        let interfaceName: String?

        enum CodingKeys: String, CodingKey {
            case downloadThroughput = "dl_throughput"
            case uploadThroughput = "ul_throughput"
            case responsiveness
            case baseRTT = "base_rtt"
            case interfaceName = "interface_name"
        }
    }
}

enum NetworkQualityError: LocalizedError {
    case processFailed(Int32)
    case missingDownload

    var errorDescription: String? {
        switch self {
        case .processFailed(let code):
            return "networkQuality è terminato con codice \(code)"
        case .missingDownload:
            return "Risposta di networkQuality senza dl_throughput"
        }
    }
}
