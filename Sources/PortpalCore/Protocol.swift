import Foundation

public enum RequestAction: String, Codable, Sendable {
    case list
    case status
    case refresh
    case stop
    case reload
    case configPath
}

public struct PortpalRequest: Codable, Sendable {
    public let action: RequestAction
    public let name: String?

    public init(action: RequestAction, name: String? = nil) {
        self.action = action
        self.name = name
    }
}

public struct PortpalResponse: Codable, Sendable {
    public let ok: Bool
    public let message: String?
    public let snapshot: ServiceSnapshot?
    public let status: ConnectionStatus?
    public let configPath: String?

    public init(
        ok: Bool,
        message: String? = nil,
        snapshot: ServiceSnapshot? = nil,
        status: ConnectionStatus? = nil,
        configPath: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.snapshot = snapshot
        self.status = status
        self.configPath = configPath
    }
}
