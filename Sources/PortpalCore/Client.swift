import Darwin
import Foundation

public enum PortpalClientError: LocalizedError {
    case socketCreateFailed
    case socketConnectFailed(String)
    case socketWriteFailed
    case socketReadFailed
    case invalidResponse
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreateFailed:
            return "Unable to create local socket."
        case .socketConnectFailed(let path):
            return "Unable to connect to Portpal daemon at \(path). Start it with brew services or run `portpal serve`."
        case .socketWriteFailed:
            return "Unable to write request to Portpal daemon."
        case .socketReadFailed:
            return "Unable to read response from Portpal daemon."
        case .invalidResponse:
            return "Portpal daemon returned an invalid response."
        case .serverError(let message):
            return message
        }
    }
}

public struct PortpalClient {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
    }

    public func listConnections() throws -> ServiceSnapshot {
        let request = PortpalRequest(action: .list)
        let response = try send(request)
        guard response.ok, let snapshot = response.snapshot else {
            throw PortpalClientError.serverError(response.message ?? "List request failed.")
        }
        return snapshot
    }

    public func refreshConnection(named name: String) throws -> ConnectionStatus {
        let request = PortpalRequest(action: .refresh, name: name)
        let response = try send(request)
        guard response.ok, let status = response.status else {
            throw PortpalClientError.serverError(response.message ?? "Refresh request failed.")
        }
        return status
    }

    public func stopConnection(named name: String) throws -> ConnectionStatus {
        let request = PortpalRequest(action: .stop, name: name)
        let response = try send(request)
        guard response.ok, let status = response.status else {
            throw PortpalClientError.serverError(response.message ?? "Stop request failed.")
        }
        return status
    }

    public func reloadConfig() throws -> ServiceSnapshot {
        let request = PortpalRequest(action: .reload)
        let response = try send(request)
        guard response.ok, let snapshot = response.snapshot else {
            throw PortpalClientError.serverError(response.message ?? "Reload request failed.")
        }
        return snapshot
    }

    private func send(_ request: PortpalRequest) throws -> PortpalResponse {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw PortpalClientError.socketCreateFailed
        }
        defer { close(socketFD) }

        var (address, length) = try SocketSupport.makeUnixAddress(for: PortpalEnvironment.socketURL.path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, length)
            }
        }
        guard result == 0 else {
            throw PortpalClientError.socketConnectFailed(PortpalEnvironment.socketURL.path)
        }

        let payload = try encoder.encode(request)
        let writeResult = payload.withUnsafeBytes { buffer in
            write(socketFD, buffer.baseAddress, buffer.count)
        }
        guard writeResult == payload.count else {
            throw PortpalClientError.socketWriteFailed
        }
        shutdown(socketFD, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(socketFD, &buffer, buffer.count)
            if bytesRead < 0 {
                throw PortpalClientError.socketReadFailed
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        guard !data.isEmpty else {
            throw PortpalClientError.invalidResponse
        }
        return try decoder.decode(PortpalResponse.self, from: data)
    }
}
