import CryptoKit
import Foundation
import Security

/// Salvataggio anonimo delle sessioni (DIAGNOSI.md 13).
public enum SessionRecorder {
    /// ~/Library/Application Support/WifiScanner/Sessions
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("WifiScanner/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sostituisce ogni BSSID con HMAC-SHA256(salt, bssid) in esadecimale, primi 12 caratteri.
    public static func anonymize(_ session: DiagnosisSession, salt: Data) -> DiagnosisSession {
        let key = SymmetricKey(data: salt)
        func pseudonym(_ bssid: String) -> String {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(bssid.lowercased().utf8), using: key)
            return mac.prefix(6).map { String(format: "%02x", Int($0)) }.joined()
        }

        var out = session
        out.link = session.link.map { sample in
            var s = sample
            s.bssid = sample.bssid.map(pseudonym)
            return s
        }
        out.events = session.events.map { event in
            var e = event
            e.bssid = event.bssid.map(pseudonym)
            return e
        }
        out.neighbors = session.neighbors.map { snapshot in
            var s = snapshot
            s.networks = snapshot.networks.map { record in
                var r = record
                r.bssid = pseudonym(record.bssid)
                return r
            }
            return s
        }
        return out
    }

    /// Anonimizza con un sale casuale e scrive il JSON. Restituisce il file.
    public static func save(_ session: DiagnosisSession) throws -> URL {
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw SessionRecorderError.randomFailed(status) }

        let data = try makeEncoder().encode(anonymize(session, salt: salt))
        let stamp = fileStamp(session.meta.start)
        let idPart = String(session.meta.id.uuidString.prefix(8)).lowercased()
        let url = directory.appendingPathComponent("session-\(stamp)-\(idPart).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// File di sessione, dal più recente.
    public static func list() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate($0) > modificationDate($1) }
    }

    public static func load(_ url: URL) throws -> DiagnosisSession {
        try makeDecoder().decode(DiagnosisSession.self, from: Data(contentsOf: url))
    }

    /// Encoder dei file di sessione.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Decoder dei file di sessione.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

private enum SessionRecorderError: Error {
    case randomFailed(OSStatus)
}
