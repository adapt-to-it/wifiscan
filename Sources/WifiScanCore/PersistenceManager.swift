import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.marcoabbattista.wifiscanner", category: "Persistence")

/// Record persistito di un dispositivo visto sulla LAN.
public struct PersistedDevice: Sendable, Hashable {
    public let mac: String           // PK normalizzato (lowercase con ':')
    public let lastIp: String?
    public let lastHostname: String?
    public let lastVendor: String?
    public let customName: String?
    public let firstSeen: Date
    public let lastSeen: Date
    public let seenCount: Int
}

/// Storage SQLite locale per device storico + statistiche.
/// Path: ~/Library/Application Support/WifiScanner/wifiscan.sqlite
public final class PersistenceManager: @unchecked Sendable {
    public static let shared = PersistenceManager()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.marcoabbattista.wifiscanner.persistence")

    private init() {
        openDatabase()
        createSchema()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Open / schema

    private static var databaseURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("WifiScanner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wifiscan.sqlite")
    }

    private func openDatabase() {
        guard let url = Self.databaseURL else {
            logger.error("Cannot determine Application Support path")
            return
        }
        let path = url.path(percentEncoded: false)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            logger.error("Failed to open DB at \(path, privacy: .public): \(self.lastError(), privacy: .public)")
            db = nil
        } else {
            logger.info("Opened DB at \(path, privacy: .public)")
            _ = exec("PRAGMA journal_mode=WAL;")
            _ = exec("PRAGMA foreign_keys=ON;")
        }
    }

    private func createSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS devices (
            mac           TEXT PRIMARY KEY,
            last_ip       TEXT,
            last_hostname TEXT,
            last_vendor   TEXT,
            custom_name   TEXT,
            first_seen    REAL NOT NULL,
            last_seen     REAL NOT NULL,
            seen_count    INTEGER NOT NULL DEFAULT 1
        );

        CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON devices(last_seen);
        """
        for statement in ddl.split(separator: ";") {
            let s = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if !exec(s) {
                logger.error("DDL failed: \(s, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func lastError() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - API

    /// Upserta un dispositivo visto adesso. Se nuovo, firstSeen = now.
    /// Restituisce true se è la prima volta che viene visto (oppure non visto da > 7 giorni → "ricomparso").
    @discardableResult
    public func recordSeen(mac: String, ip: String?, hostname: String?, vendor: String?,
                           at date: Date = Date()) -> Bool {
        queue.sync {
            guard let db else { return false }
            let key = Self.normalizeMAC(mac)
            let ts = date.timeIntervalSince1970

            // Leggi stato corrente
            let existing = readDevice(key: key)

            if let existing = existing {
                // Update
                let sql = """
                UPDATE devices
                SET last_ip = ?, last_hostname = ?, last_vendor = ?,
                    last_seen = ?, seen_count = seen_count + 1
                WHERE mac = ?;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, ip)
                bindText(stmt, 2, hostname)
                bindText(stmt, 3, vendor)
                sqlite3_bind_double(stmt, 4, ts)
                bindText(stmt, 5, key)
                _ = sqlite3_step(stmt)
                // È "ricomparso" se non visto da > 7 giorni
                let elapsed = date.timeIntervalSince(existing.lastSeen)
                return elapsed > (7 * 24 * 3600)
            } else {
                // Insert
                let sql = """
                INSERT INTO devices (mac, last_ip, last_hostname, last_vendor, first_seen, last_seen, seen_count)
                VALUES (?, ?, ?, ?, ?, ?, 1);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, key)
                bindText(stmt, 2, ip)
                bindText(stmt, 3, hostname)
                bindText(stmt, 4, vendor)
                sqlite3_bind_double(stmt, 5, ts)
                sqlite3_bind_double(stmt, 6, ts)
                _ = sqlite3_step(stmt)
                return true   // primo avvistamento
            }
        }
    }

    /// Imposta un nome custom per un MAC.
    public func setCustomName(_ name: String?, for mac: String) {
        queue.sync {
            guard let db else { return }
            let key = Self.normalizeMAC(mac)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE devices SET custom_name = ? WHERE mac = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, name)
            bindText(stmt, 2, key)
            _ = sqlite3_step(stmt)
        }
    }

    /// Vero se non è ancora stato registrato nessun dispositivo.
    public var isEmpty: Bool {
        queue.sync {
            guard let db else { return true }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM devices LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return true }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) != SQLITE_ROW
        }
    }

    /// Cancella un dispositivo dallo storico.
    public func delete(mac: String) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM devices WHERE mac = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.normalizeMAC(mac))
            _ = sqlite3_step(stmt)
        }
    }

    /// Cancella tutto lo storico dei dispositivi, nomi personalizzati compresi.
    public func deleteAll() {
        queue.sync { _ = exec("DELETE FROM devices;") }
    }

    /// Legge record per MAC.
    public func device(for mac: String) -> PersistedDevice? {
        queue.sync {
            readDevice(key: Self.normalizeMAC(mac))
        }
    }

    /// Restituisce tutti i device noti.
    public func allDevices() -> [PersistedDevice] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT mac, last_ip, last_hostname, last_vendor, custom_name, first_seen, last_seen, seen_count FROM devices ORDER BY last_seen DESC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var result: [PersistedDevice] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let d = parseRow(stmt) { result.append(d) }
            }
            return result
        }
    }

    // MARK: - Private helpers

    private func readDevice(key: String) -> PersistedDevice? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT mac, last_ip, last_hostname, last_vendor, custom_name, first_seen, last_seen, seen_count FROM devices WHERE mac = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRow(stmt)
    }

    private func parseRow(_ stmt: OpaquePointer?) -> PersistedDevice? {
        guard let stmt else { return nil }
        let mac = readText(stmt, 0) ?? ""
        return PersistedDevice(
            mac: mac,
            lastIp: readText(stmt, 1),
            lastHostname: readText(stmt, 2),
            lastVendor: readText(stmt, 3),
            customName: readText(stmt, 4),
            firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            seenCount: Int(sqlite3_column_int64(stmt, 7))
        )
    }

    // SQLITE_TRANSIENT è "-1 castato a una funzione destructor" → SQLite copia internamente la stringa
    private static let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        guard let value = value else {
            sqlite3_bind_null(stmt, idx)
            return
        }
        sqlite3_bind_text(stmt, idx, value, -1, Self.SQLITE_TRANSIENT)
    }

    private func readText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }

    public static func normalizeMAC(_ raw: String) -> String {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 6 else { return raw.lowercased() }
        let padded = parts.map { $0.count == 1 ? "0\($0)" : $0 }
        return padded.joined(separator: ":").lowercased()
    }
}
