import Foundation

/// Nodo del tailnet visto da `tailscale status --json`.
public struct TailscalePeer: Sendable {
    public let hostName: String
    public let dnsName: String?
    public let os: String
    public let ipv4: String?
    public let isSelf: Bool
}

/// Subnet IPv4 pubblicata da un subnet router (o exit node) e accettata da questo Mac.
public struct TailscaleRoute: Sendable {
    public let cidr: String     // es. "192.168.1.0/24"
    public let via: String      // hostname del router, es. "ts-exit"
}

public struct TailscaleStatus: Sendable {
    public let peers: [TailscalePeer]
    public let routes: [TailscaleRoute]
}

/// Legge lo stato di Tailscale tramite la CLI. Restituisce nil se Tailscale non è installato o non è attivo.
public enum TailscaleInspector {
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    public static func status() async -> TailscaleStatus? {
        guard let cli = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let data: Data? = await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cli)
            proc.arguments = ["status", "--json"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                return proc.terminationStatus == 0 ? data : nil
            } catch {
                return nil
            }
        }.value
        return data.flatMap(parse)
    }

    public static func parse(_ data: Data) -> TailscaleStatus? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              raw.BackendState == "Running" else { return nil }

        var peers = [peer(raw.Self, isSelf: true)]
        var routes: [TailscaleRoute] = []
        for node in (raw.Peer ?? [:]).values where node.Online == true {
            peers.append(peer(node, isSelf: false))
            // Solo le route IPv4 accettate (presenti anche in AllowedIPs), escluso il default dell'exit node.
            let allowed = Set(node.AllowedIPs ?? [])
            for cidr in node.PrimaryRoutes ?? [] where allowed.contains(cidr) && cidr.contains(".")
                && cidr != "0.0.0.0/0" {
                routes.append(TailscaleRoute(cidr: cidr, via: node.HostName))
            }
        }
        return TailscaleStatus(peers: peers, routes: routes)
    }

    private static func peer(_ n: Raw.Node, isSelf: Bool) -> TailscalePeer {
        let dns = n.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return TailscalePeer(hostName: n.HostName, dnsName: dns?.isEmpty == true ? nil : dns,
                             os: n.OS ?? "", ipv4: n.TailscaleIPs?.first { $0.contains(".") },
                             isSelf: isSelf)
    }

    // Sottoinsieme dello schema JSON di `tailscale status --json`.
    private struct Raw: Decodable {
        let BackendState: String
        let `Self`: Node
        let Peer: [String: Node]?

        struct Node: Decodable {
            let HostName: String
            let DNSName: String?
            let OS: String?
            let TailscaleIPs: [String]?
            let Online: Bool?
            let PrimaryRoutes: [String]?
            let AllowedIPs: [String]?
        }
    }
}
