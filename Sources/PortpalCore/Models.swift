import Foundation

public enum ConnectionState: String, Codable, Sendable {
    case healthy
    case starting
    case waitingToRetry
    case stopped
    case failed
}

public struct ConnectionStatus: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sshHost: String
    public let localPort: Int
    public let remoteHost: String
    public let remotePort: Int
    public let autoStart: Bool
    public let reconnectDelaySeconds: Int
    public let processID: Int?
    public let processAlive: Bool
    public let portReachable: Bool
    public let state: ConnectionState
    public let restartSuppressed: Bool
    public let lastError: String?
    public let nextRetryInSeconds: Int?

    public init(
        name: String,
        sshHost: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        autoStart: Bool,
        reconnectDelaySeconds: Int,
        processID: Int?,
        processAlive: Bool,
        portReachable: Bool,
        state: ConnectionState,
        restartSuppressed: Bool,
        lastError: String?,
        nextRetryInSeconds: Int?
    ) {
        self.id = name
        self.name = name
        self.sshHost = sshHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.autoStart = autoStart
        self.reconnectDelaySeconds = reconnectDelaySeconds
        self.processID = processID
        self.processAlive = processAlive
        self.portReachable = portReachable
        self.state = state
        self.restartSuppressed = restartSuppressed
        self.lastError = lastError
        self.nextRetryInSeconds = nextRetryInSeconds
    }

    public var displayName: String {
        name
    }

    public var detailText: String {
        let base = "\(sshHost):\(localPort) -> \(remoteHost):\(remotePort)"
        switch state {
        case .healthy:
            return base
        case .starting:
            return "Starting. \(base)"
        case .waitingToRetry:
            if let nextRetryInSeconds {
                return "Retrying in \(nextRetryInSeconds)s. \(base)"
            }
            return "Waiting to retry. \(base)"
        case .stopped:
            return "Stopped. \(base)"
        case .failed:
            if let lastError, !lastError.isEmpty {
                return "Failed: \(lastError)"
            }
            return "Failed. \(base)"
        }
    }
}

public enum AggregateHealth: String, Codable, Sendable {
    case empty
    case allHealthy
    case noneHealthy
    case mixed
}

public struct ServiceSnapshot: Codable, Sendable {
    public let connections: [ConnectionStatus]
    public let aggregateHealth: AggregateHealth

    public init(connections: [ConnectionStatus], aggregateHealth: AggregateHealth) {
        self.connections = connections
        self.aggregateHealth = aggregateHealth
    }
}
