import Foundation

public enum RequestAction: String, Codable, Sendable {
    case createTunnel
    case checkTunnel
    case listTunnels
    case removeTunnel
}

public struct TunnelLookup: Codable, Sendable {
    public let sshHost: String
    public let localPort: Int

    public init(sshHost: String, localPort: Int) {
        self.sshHost = sshHost
        self.localPort = localPort
    }
}

public struct PortpalRequest: Codable, Sendable {
    public let action: RequestAction
    public let tunnel: TunnelSpec?
    public let lookup: TunnelLookup?
    public let name: String?

    public init(action: RequestAction, tunnel: TunnelSpec? = nil, lookup: TunnelLookup? = nil, name: String? = nil) {
        self.action = action
        self.tunnel = tunnel
        self.lookup = lookup
        self.name = name
    }
}

public struct CreateTunnelResult: Codable, Sendable {
    public let created: Bool
    public let started: Bool
    public let status: TunnelStatus

    public init(created: Bool, started: Bool, status: TunnelStatus) {
        self.created = created
        self.started = started
        self.status = status
    }
}

public struct CheckTunnelResult: Codable, Sendable {
    public let managed: Bool
    public let healthy: Bool
    public let processAlive: Bool
    public let portReachable: Bool
    public let status: TunnelStatus?

    public init(managed: Bool, healthy: Bool, processAlive: Bool, portReachable: Bool, status: TunnelStatus?) {
        self.managed = managed
        self.healthy = healthy
        self.processAlive = processAlive
        self.portReachable = portReachable
        self.status = status
    }
}

public struct PortpalResponse: Codable, Sendable {
    public let ok: Bool
    public let message: String?
    public let createResult: CreateTunnelResult?
    public let checkResult: CheckTunnelResult?
    public let snapshot: ServiceSnapshot?
    public let removeResult: RemoveTunnelResult?

    public init(
        ok: Bool,
        message: String? = nil,
        createResult: CreateTunnelResult? = nil,
        checkResult: CheckTunnelResult? = nil,
        snapshot: ServiceSnapshot? = nil,
        removeResult: RemoveTunnelResult? = nil
    ) {
        self.ok = ok
        self.message = message
        self.createResult = createResult
        self.checkResult = checkResult
        self.snapshot = snapshot
        self.removeResult = removeResult
    }
}
