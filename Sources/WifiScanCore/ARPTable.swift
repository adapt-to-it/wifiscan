import Foundation

/// Una entry della ARP cache: IP ↔ MAC visto.
public struct ARPEntry: Sendable, Hashable {
    public let ip: String
    public let mac: String      // normalizzato lowercase con `:`
    public let interface: String  // es. "en0"

    public init(ip: String, mac: String, interface: String) {
        self.ip = ip
        self.mac = mac
        self.interface = interface
    }
}

/// Wrapper su `/usr/sbin/arp` per leggere la ARP cache del kernel.
/// Funziona senza permessi speciali; output è parsato direttamente.
public enum ARPTable {
    /// Legge l'intera ARP cache filtrata sull'interfaccia data (es. "en0").
    /// Se interfaceFilter è nil, ritorna tutte le entry.
    public static func read(interfaceFilter: String? = nil) async -> [ARPEntry] {
        let output = await runARP()
        return parse(output, interfaceFilter: interfaceFilter)
    }

    private static func runARP() async -> String {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            proc.arguments = ["-a", "-n"]   // numerico, no risoluzione DNS
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                return ""
            }
        }.value
    }

    /// Parsa output di `arp -a -n`. Linea tipo:
    /// `? (192.168.1.1) at a4:2b:b0:74:8e:1c on en0 ifscope [ethernet]`
    /// `? (192.168.1.42) at (incomplete) on en0 ifscope [ethernet]`
    public static func parse(_ text: String, interfaceFilter: String? = nil) -> [ARPEntry] {
        var result: [ARPEntry] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            // Estrai IP tra parentesi
            guard let openParen = s.firstIndex(of: "("),
                  let closeParen = s.firstIndex(of: ")"),
                  openParen < closeParen
            else { continue }
            let ip = String(s[s.index(after: openParen)..<closeParen])
            // Estrai MAC dopo "at "
            guard let atRange = s.range(of: " at ") else { continue }
            let after = s[atRange.upperBound...]
            let macToken = after.split(separator: " ").first.map(String.init) ?? ""
            // Filtra incomplete
            if macToken.contains("incomplete") || macToken.isEmpty { continue }
            // Normalizza MAC (aggiungi zero davanti ai byte di una sola cifra)
            let normalized = normalizeMAC(macToken)
            guard normalized.count == 17 else { continue }
            // Estrai interface dopo "on "
            guard let onRange = s.range(of: " on ") else { continue }
            let afterOn = s[onRange.upperBound...]
            let iface = afterOn.split(separator: " ").first.map(String.init) ?? ""
            if let filter = interfaceFilter, iface != filter { continue }
            result.append(ARPEntry(ip: ip, mac: normalized, interface: iface))
        }
        return result
    }

    /// Normalizza un MAC come "a4:2b:b0:74:8e:1c" da formati abbreviati tipo "4:2b:b0:7:8e:c".
    public static func normalizeMAC(_ raw: String) -> String {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 6 else { return raw }
        let padded = parts.map { $0.count == 1 ? "0\($0)" : $0 }
        return padded.joined(separator: ":").lowercased()
    }
}
