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

    private enum CodingKeys: String, CodingKey {
        case name
        case sshHost
        case localPort
        case remoteHost
        case remotePort
        case autoStart
        case reconnectDelaySeconds
        case processID
        case processAlive
        case portReachable
        case state
        case restartSuppressed
        case lastError
        case nextRetryInSeconds
    }

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)

        self.init(
            name: name,
            sshHost: try container.decode(String.self, forKey: .sshHost),
            localPort: try container.decode(Int.self, forKey: .localPort),
            remoteHost: try container.decode(String.self, forKey: .remoteHost),
            remotePort: try container.decode(Int.self, forKey: .remotePort),
            autoStart: try container.decode(Bool.self, forKey: .autoStart),
            reconnectDelaySeconds: try container.decode(Int.self, forKey: .reconnectDelaySeconds),
            processID: try container.decodeIfPresent(Int.self, forKey: .processID),
            processAlive: try container.decode(Bool.self, forKey: .processAlive),
            portReachable: try container.decode(Bool.self, forKey: .portReachable),
            state: try container.decode(ConnectionState.self, forKey: .state),
            restartSuppressed: try container.decode(Bool.self, forKey: .restartSuppressed),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            nextRetryInSeconds: try container.decodeIfPresent(Int.self, forKey: .nextRetryInSeconds)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(sshHost, forKey: .sshHost)
        try container.encode(localPort, forKey: .localPort)
        try container.encode(remoteHost, forKey: .remoteHost)
        try container.encode(remotePort, forKey: .remotePort)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(reconnectDelaySeconds, forKey: .reconnectDelaySeconds)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encode(processAlive, forKey: .processAlive)
        try container.encode(portReachable, forKey: .portReachable)
        try container.encode(state, forKey: .state)
        try container.encode(restartSuppressed, forKey: .restartSuppressed)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(nextRetryInSeconds, forKey: .nextRetryInSeconds)
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
