import Foundation

/// Contatori e stato delle interfacce (N14, N15, N17).
public enum InterfaceStats {
    public static func sample(wifiInterface: String) -> InterfaceSample {
        var wifiTx: UInt64 = 0
        var wifiRx: UInt64 = 0
        var awdlUp = false
        var awdlTx: UInt64 = 0
        var etherCandidates = Set<String>()
        var ipv4Interfaces = Set<String>()

        var head: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&head) == 0 {
            var cursor = head
            while let ifa = cursor {
                cursor = ifa.pointee.ifa_next
                guard let addr = ifa.pointee.ifa_addr else { continue }
                let name = String(cString: ifa.pointee.ifa_name)
                let family = Int32(addr.pointee.sa_family)
                if family == AF_INET {
                    ipv4Interfaces.insert(name)
                } else if family == AF_LINK, let raw = ifa.pointee.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    let flags = ifa.pointee.ifa_flags
                    let running = (flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_RUNNING)) != 0
                    if name == wifiInterface {
                        wifiTx = UInt64(data.ifi_obytes)
                        wifiRx = UInt64(data.ifi_ibytes)
                    } else if name == "awdl0" {
                        awdlUp = running
                        awdlTx = UInt64(data.ifi_obytes)
                    } else if name.hasPrefix("en") && running && Int32(data.ifi_type) == IFT_ETHER {
                        etherCandidates.insert(name)
                    }
                }
            }
            freeifaddrs(head)
        }

        var defaultRoute: String? = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", "inet"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            defaultRoute = parseDefaultInterface(netstat: String(decoding: output, as: UTF8.self))
        }

        return InterfaceSample(
            t: Date(),
            wifiTxBytes: wifiTx,
            wifiRxBytes: wifiRx,
            defaultRouteInterface: defaultRoute,
            ethernetActive: !etherCandidates.isDisjoint(with: ipv4Interfaces),
            awdlUp: awdlUp,
            awdlTxBytes: awdlTx
        )
    }

    /// Colonna Netif della prima riga "default" di `netstat -rn -f inet`.
    static func parseDefaultInterface(netstat: String) -> String? {
        let lines = netstat.split(separator: "\n", omittingEmptySubsequences: false)
        guard let headerIndex = lines.firstIndex(where: { $0.contains("Netif") }) else { return nil }
        let headerColumns = lines[headerIndex].split(whereSeparator: { $0.isWhitespace })
        guard let netifColumn = headerColumns.firstIndex(where: { $0 == "Netif" }) else { return nil }
        for line in lines[(headerIndex + 1)...] where line.hasPrefix("default") {
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            return netifColumn < columns.count ? String(columns[netifColumn]) : nil
        }
        return nil
    }
}
