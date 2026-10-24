import Foundation

/// Lookup vendor da indirizzo MAC usando database IEEE OUI (sorgente: Wireshark manuf).
///
/// Database compatto: dizionario [String: String] dove la chiave è "prefix_hex@mask".
/// Lookup: prova mask più specifica (36, 28) e fa fallback a /24.
public final class OUILookup: @unchecked Sendable {
    public static let shared = OUILookup()

    private let dict: [String: String]

    public init() {
        // Nell'app distribuita oui.plist sta in Contents/Resources. `Bundle.module` cerca solo accanto
        // al .app o nella cartella .build di chi compila, e va in fatalError se non trova nulla:
        // lo usiamo solo come fallback per la CLI eseguita da .build.
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "plist")
                ?? Bundle.module.url(forResource: "oui", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let parsed = try? PropertyListDecoder().decode([String: String].self, from: data)
        else {
            self.dict = [:]
            return
        }
        self.dict = parsed
    }

    /// Restituisce il nome vendor per un MAC normalizzato (es. "0a:c7:f5:96:72:33" o "0AC7F5967233").
    /// Restituisce nil se non trovato o MAC malformato.
    public func vendor(for mac: String) -> String? {
        // Normalizza: rimuovi `:` e `-`, lowercase
        let hex = mac
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard hex.count >= 6 else { return nil }
        // Filtra solo hex char (cautela contro input malformati)
        for ch in hex.prefix(9) {
            if !ch.isHexDigit { return nil }
        }
        // Prova /36, /28, /24 in cascata (la mask più lunga vince)
        for mask in [36, 28, 24] {
            let nibbles = mask / 4
            guard hex.count >= nibbles else { continue }
            let prefix = String(hex.prefix(nibbles))
            if let v = dict["\(prefix)@\(mask)"] { return v }
        }
        return nil
    }

    /// Numero di entries caricate (per debug/sanità).
    public var entryCount: Int { dict.count }
}
