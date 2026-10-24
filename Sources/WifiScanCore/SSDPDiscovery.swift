import Foundation
import Darwin

/// Dispositivo UPnP trovato via SSDP.
public struct SSDPDevice: Sendable, Hashable {
    public let ip: String
    public var friendlyName: String?
    public var manufacturer: String?
    public var modelName: String?
    public var server: String?       // header SERVER
    public var location: String?     // header LOCATION

    public init(ip: String) { self.ip = ip }
}

private typealias Description = (friendlyName: String?, manufacturer: String?, modelName: String?)

public enum SSDPDiscovery {
    private static let multicastAddress = "239.255.255.250"
    private static let port: UInt16 = 1900
    private static let mSearch = "M-SEARCH * HTTP/1.1\r\n"
        + "HOST: 239.255.255.250:1900\r\n"
        + "MAN: \"ssdp:discover\"\r\n"
        + "MX: 2\r\n"
        + "ST: ssdp:all\r\n"
        + "\r\n"

    /// M-SEARCH ssdp:all su 239.255.255.250:1900, raccoglie risposte per `duration`,
    /// poi legge i descrittori XML. Un elemento per IP.
    /// `interfaceAddress`: IPv4 locale da cui far uscire il multicast. Serve con VPN o exit node,
    /// che altrimenti instradano 239.255.255.250 nel tunnel.
    public static func discover(duration: TimeInterval = 3.0,
                                interfaceAddress: String? = nil) async -> [SSDPDevice] {
        var devices = await collectResponses(duration: duration, interfaceAddress: interfaceAddress)
        guard !devices.isEmpty else { return [] }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        await withTaskGroup(of: (Int, Description?).self) { group in
            for (i, device) in devices.enumerated() {
                guard let location = device.location,
                      let url = URL(string: location),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }
                group.addTask {
                    // Errori e timeout di rete: il dispositivo resta senza descrizione.
                    guard let result = try? await session.data(from: url) else { return (i, nil) }
                    return (i, parseDescription(result.0))
                }
            }
            for await (i, description) in group {
                guard let description = description else { continue }
                devices[i].friendlyName = description.friendlyName
                devices[i].manufacturer = description.manufacturer
                devices[i].modelName = description.modelName
            }
        }
        return devices
    }

    /// Header della risposta HTTPU, chiavi in maiuscolo.
    public static func parseResponse(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Le righe senza ":" (la status line "HTTP/1.1 200 OK", le righe vuote) non sono header.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            headers[key] = value
        }
        return headers
    }

    public static func parseDescription(_ xml: Data) -> (friendlyName: String?, manufacturer: String?, modelName: String?) {
        let delegate = DescriptionParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        // XML malformato: il descrittore non è affidabile, nessun campo.
        guard parser.parse() else { return (nil, nil, nil) }
        return (delegate.friendlyName, delegate.manufacturer, delegate.modelName)
    }

    private static func collectResponses(duration: TimeInterval, interfaceAddress: String?) async -> [SSDPDevice] {
        await withCheckedContinuation { cont in
            // Thread GCD dedicato: recvfrom/poll bloccano, quindi restano fuori dal pool cooperativo.
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: receive(duration: duration, interfaceAddress: interfaceAddress))
            }
        }
    }

    private static func receive(duration: TimeInterval, interfaceAddress: String?) -> [SSDPDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        if let interfaceAddress {
            var ifAddr = in_addr()
            if inet_pton(AF_INET, interfaceAddress, &ifAddr) == 1 {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
            }
        }

        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, multicastAddress, &dst.sin_addr)

        // Due M-SEARCH: UDP non garantisce la consegna di un singolo pacchetto.
        let payload = Array(mSearch.utf8)
        for round in 0..<2 {
            if round > 0 { usleep(100_000) }
            _ = withUnsafePointer(to: dst) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var devices: [String: SSDPDevice] = [:]
        var order: [String] = []
        var buf = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(duration)
        var left = duration
        while left > 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, Int32(left * 1000) + 1) > 0 {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buf, buf.count, MSG_DONTWAIT, sa, &len)
                    }
                }
                if n > 0 {
                    var addr = from.sin_addr
                    var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: ipBuf)
                    let headers = parseResponse(String(decoding: buf[0..<n], as: UTF8.self))
                    if !headers.isEmpty {
                        // Per IP tiene il primo LOCATION e il primo SERVER ricevuti.
                        if devices[ip] == nil { order.append(ip) }
                        var device = devices[ip] ?? SSDPDevice(ip: ip)
                        if device.location == nil { device.location = headers["LOCATION"] }
                        if device.server == nil { device.server = headers["SERVER"] }
                        devices[ip] = device
                    }
                }
            }
            left = deadline.timeIntervalSinceNow
        }
        return order.compactMap { devices[$0] }
    }
}

/// Estrae friendlyName, manufacturer e modelName dei figli diretti del primo `device`.
private final class DescriptionParser: NSObject, XMLParserDelegate {
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?

    private var path: [String] = []
    private var text: String?   // testo dell'elemento corrente, nil se non è un campo che ci serve

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        path.append(elementName)
        // Radice > device > campo: esclude i device annidati (deviceList).
        let directChild = path.count == 3 && path[1] == "device"
        let isField = ["friendlyName", "manufacturer", "modelName"].contains(elementName)
        text = directChild && isField ? "" : nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let chunk = String(data: CDATABlock, encoding: .utf8) { text?.append(chunk) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            switch elementName {
            case "friendlyName": if friendlyName == nil { friendlyName = value }
            case "manufacturer": if manufacturer == nil { manufacturer = value }
            case "modelName": if modelName == nil { modelName = value }
            default: break
            }
        }
        text = nil
        path.removeLast()
    }
}

public enum MACAddress {
    /// Bit "locally administered" (0x02 del primo byte): MAC casuale di iOS, Android, Windows.
    public static func isRandomized(_ mac: String) -> Bool {
        let octets = mac.split(separator: ":", omittingEmptySubsequences: false)
        // Sei gruppi esadecimali da 1 o 2 cifre (arp stampa gli zeri iniziali a volte omessi).
        guard octets.count == 6,
              octets.allSatisfy({ octet in (1...2).contains(octet.count) && octet.allSatisfy { $0.isHexDigit } }),
              let first = UInt8(octets[0], radix: 16) else { return false }
        return first & 0x02 != 0
    }
}
