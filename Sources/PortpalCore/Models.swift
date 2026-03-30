import Foundation

public struct TunnelSpec: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String?
    public var sshHost: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        sshHost: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) {
        self.id = id
        self.name = name?.nilIfBlank
        self.sshHost = sshHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    public var displayName: String {
        name ?? "\(sshHost):\(localPort)"
    }

    public func matchesRemovalName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if let name, name == trimmed {
            return true
        }
        return displayName == trimmed
    }

    public func validate() throws {
        guard !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelValidationError.emptySSHHost
        }
        guard !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelValidationError.emptyRemoteHost
        }
        guard Self.isValidPort(localPort) else {
            throw TunnelValidationError.invalidLocalPort(localPort)
        }
        guard Self.isValidPort(remotePort) else {
            throw TunnelValidationError.invalidRemotePort(remotePort)
        }
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }
}

public enum TunnelValidationError: LocalizedError, Equatable, Sendable {
    case emptySSHHost
    case emptyRemoteHost
    case invalidLocalPort(Int)
    case invalidRemotePort(Int)
    case duplicateTunnel(String, Int)

    public var errorDescription: String? {
        switch self {
        case .emptySSHHost:
            return "SSH host is required."
        case .emptyRemoteHost:
            return "Remote host is required."
        case .invalidLocalPort(let port):
            return "Invalid local port: \(port)."
        case .invalidRemotePort(let port):
            return "Invalid remote port: \(port)."
        case .duplicateTunnel(let host, let port):
            return "Tunnel \(host):\(port) is already managed."
        }
    }
}

public enum TunnelHealth: String, Codable, Sendable {
    case healthy
    case unhealthy
}

public struct TunnelStatus: Codable, Identifiable, Sendable {
    public let id: UUID
    public let spec: TunnelSpec
    public let isManaged: Bool
    public let processID: Int32?
    public let processAlive: Bool
    public let portReachable: Bool
    public let lastCheckedAt: Date?
    public let health: TunnelHealth

    public init(
        spec: TunnelSpec,
        isManaged: Bool,
        processID: Int32?,
        processAlive: Bool,
        portReachable: Bool,
        lastCheckedAt: Date?
    ) {
        self.id = spec.id
        self.spec = spec
        self.isManaged = isManaged
        self.processID = processID
        self.processAlive = processAlive
        self.portReachable = portReachable
        self.lastCheckedAt = lastCheckedAt
        self.health = (processAlive && portReachable) ? .healthy : .unhealthy
    }
}

public enum AggregateHealth: String, Codable, Sendable {
    case empty
    case allHealthy
    case noneHealthy
    case mixed

    public static func from(statuses: [TunnelStatus]) -> AggregateHealth {
        guard !statuses.isEmpty else {
            return .empty
        }

        let healthyCount = statuses.filter { $0.health == .healthy }.count
        if healthyCount == statuses.count {
            return .allHealthy
        }
        if healthyCount == 0 {
            return .noneHealthy
        }
        return .mixed
    }
}

public struct ServiceSnapshot: Codable, Sendable {
    public let tunnels: [TunnelStatus]
    public let aggregateHealth: AggregateHealth

    public init(tunnels: [TunnelStatus]) {
        self.tunnels = tunnels.sorted { $0.spec.displayName.localizedCaseInsensitiveCompare($1.spec.displayName) == .orderedAscending }
        self.aggregateHealth = AggregateHealth.from(statuses: tunnels)
    }
}

public struct RemoveTunnelResult: Codable, Sendable {
    public let removed: Bool
    public let name: String
    public let status: TunnelStatus?

    public init(removed: Bool, name: String, status: TunnelStatus?) {
        self.removed = removed
        self.name = name
        self.status = status
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
