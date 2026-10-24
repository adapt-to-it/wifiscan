import Foundation
import Darwin
import os.log

private let logger = Logger(subsystem: "com.marcoabbattista.wifiscanner", category: "LocalNetwork")

/// Subnet IPv4 della rete locale + utility per generare la lista degli IP da scansionare.
public struct LocalSubnet: Sendable, Equatable {
    public let interface: String   // es. "en0"
    public let address: String     // IP locale, es. "192.168.1.42"
    public let netmask: String     // es. "255.255.255.0"
    public let prefixLength: Int   // es. 24
    public let networkAddress: String   // es. "192.168.1.0"
    public let broadcastAddress: String // es. "192.168.1.255"

    public init(interface: String, address: String, netmask: String,
                prefixLength: Int, networkAddress: String, broadcastAddress: String) {
        self.interface = interface
        self.address = address
        self.netmask = netmask
        self.prefixLength = prefixLength
        self.networkAddress = networkAddress
        self.broadcastAddress = broadcastAddress
    }

    /// Lista di IP da scansionare (esclusi network e broadcast).
    public func hostAddresses() -> [String] {
        guard prefixLength >= 16 else { return [] }  // sicurezza: niente scan di /15 o più grandi
        guard let networkInt = Self.ipv4ToUInt32(networkAddress),
              let broadcastInt = Self.ipv4ToUInt32(broadcastAddress) else { return [] }
        guard broadcastInt > networkInt + 1 else { return [] }
        var hosts: [String] = []
        for ip in (networkInt + 1)..<broadcastInt {
            hosts.append(Self.uint32ToIPv4(ip))
        }
        return hosts
    }

    /// Subnet da notazione CIDR, es. "192.168.1.0/24". `address` è l'indirizzo di rete.
    public init?(cidr: String, interface: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (1...32).contains(prefix),
              let ip = Self.ipv4ToUInt32(String(parts[0])) else { return nil }
        let mask: UInt32 = prefix == 32 ? .max : ~(UInt32.max >> UInt32(prefix))
        let network = ip & mask
        self.init(interface: interface,
                  address: Self.uint32ToIPv4(network),
                  netmask: Self.uint32ToIPv4(mask),
                  prefixLength: prefix,
                  networkAddress: Self.uint32ToIPv4(network),
                  broadcastAddress: Self.uint32ToIPv4(network | ~mask))
    }

    /// True se le due subnet condividono almeno un indirizzo.
    public func overlaps(_ other: LocalSubnet) -> Bool {
        guard let a = Self.ipv4ToUInt32(networkAddress), let b = Self.ipv4ToUInt32(other.networkAddress)
        else { return false }
        let shorter = min(prefixLength, other.prefixLength)
        let mask: UInt32 = shorter == 0 ? 0 : ~(UInt32.max >> UInt32(shorter))
        return a & mask == b & mask
    }

    public var hostCount: Int {
        let bits = 32 - prefixLength
        return (1 << bits) - 2
    }

    // MARK: - Helpers

    public static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    public static func uint32ToIPv4(_ n: UInt32) -> String {
        "\((n >> 24) & 0xff).\((n >> 16) & 0xff).\((n >> 8) & 0xff).\(n & 0xff)"
    }

    public static func netmaskPrefixLength(_ mask: String) -> Int? {
        guard let n = ipv4ToUInt32(mask) else { return nil }
        // Verifica che sia una valida netmask (1s contigui poi 0s)
        let inverted = ~n
        if (inverted & (inverted + 1)) != 0 { return nil }
        return n.nonzeroBitCount
    }
}

public enum LocalNetworkInspector {
    /// Trova la subnet attiva. Preferisce `preferring` se trovato, altrimenti
    /// prende la prima interfaccia non-loopback con IP privato (192.168/16, 10/8, 172.16/12).
    public static func detectActiveSubnet(preferring interfaceName: String = "en0") -> LocalSubnet? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstIfaddr = ifaddrPtr else {
            logger.error("getifaddrs failed")
            return nil
        }
        defer { freeifaddrs(ifaddrPtr) }

        var preferredFound: LocalSubnet?
        var anyPrivateFound: LocalSubnet?

        var current: UnsafeMutablePointer<ifaddrs>? = firstIfaddr
        while let ptr = current {
            defer { current = ptr.pointee.ifa_next }
            let ifa = ptr.pointee
            guard let saAddr = ifa.ifa_addr, let saMask = ifa.ifa_netmask else { continue }
            let family = saAddr.pointee.sa_family
            guard family == sa_family_t(AF_INET) else { continue }

            let nameStr = String(cString: ifa.ifa_name)
            if nameStr == "lo0" { continue }
            // Filtra interfacce virtuali (utun, awdl, llw) di sistema
            if nameStr.hasPrefix("utun") || nameStr.hasPrefix("awdl") || nameStr.hasPrefix("llw") ||
               nameStr.hasPrefix("anpi") || nameStr.hasPrefix("bridge") {
                continue
            }

            guard let ip = Self.sockaddrToString(saAddr),
                  let mask = Self.sockaddrToString(saMask),
                  !ip.isEmpty, !mask.isEmpty,
                  let prefix = LocalSubnet.netmaskPrefixLength(mask),
                  let ipInt = LocalSubnet.ipv4ToUInt32(ip),
                  let maskInt = LocalSubnet.ipv4ToUInt32(mask)
            else { continue }

            // Solo IP private RFC1918
            let isPrivate = ip.hasPrefix("192.168.") ||
                            ip.hasPrefix("10.") ||
                            (ip.hasPrefix("172.") && {
                                let parts = ip.split(separator: ".")
                                if parts.count >= 2, let second = Int(parts[1]) {
                                    return (16...31).contains(second)
                                }
                                return false
                            }())
            if !isPrivate { continue }

            let network = ipInt & maskInt
            let broadcast = network | (~maskInt)
            let subnet = LocalSubnet(
                interface: nameStr,
                address: ip,
                netmask: mask,
                prefixLength: prefix,
                networkAddress: LocalSubnet.uint32ToIPv4(network),
                broadcastAddress: LocalSubnet.uint32ToIPv4(broadcast)
            )

            logger.info("Found candidate subnet: \(nameStr, privacy: .public) \(ip, privacy: .public)/\(prefix)")

            if nameStr == interfaceName {
                preferredFound = subnet
            }
            if anyPrivateFound == nil {
                anyPrivateFound = subnet
            }
        }

        let chosen = preferredFound ?? anyPrivateFound
        if let chosen = chosen {
            logger.info("Selected subnet: \(chosen.interface, privacy: .public) \(chosen.address, privacy: .public)/\(chosen.prefixLength)")
        } else {
            logger.error("No suitable subnet found")
        }
        return chosen
    }

    private static func sockaddrToString(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = getnameinfo(
            sa,
            socklen_t(sa.pointee.sa_len),
            &buffer,
            socklen_t(buffer.count),
            nil, 0,
            NI_NUMERICHOST
        )
        if result == 0 {
            return String(cString: buffer)
        }
        return nil
    }
}
