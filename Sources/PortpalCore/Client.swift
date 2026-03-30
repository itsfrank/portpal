import Darwin
import Foundation

public enum PortpalClientError: LocalizedError {
    case serviceNotFound(String)
    case serviceDidNotStart
    case socketCreateFailed
    case socketConnectFailed(String)
    case socketWriteFailed
    case socketReadFailed
    case invalidResponse
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .serviceNotFound(let path):
            return "Portpal service executable not found at \(path)."
        case .serviceDidNotStart:
            return "Portpal service did not start in time."
        case .socketCreateFailed:
            return "Unable to create local socket."
        case .socketConnectFailed(let path):
            return "Unable to connect to Portpal service at \(path)."
        case .socketWriteFailed:
            return "Unable to write request to Portpal service."
        case .socketReadFailed:
            return "Unable to read response from Portpal service."
        case .invalidResponse:
            return "Portpal service returned an invalid response."
        case .serverError(let message):
            return message
        }
    }
}

public struct PortpalClient {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func createTunnel(_ tunnel: TunnelSpec) throws -> CreateTunnelResult {
        let request = PortpalRequest(action: .createTunnel, tunnel: tunnel)
        let response = try send(request)
        guard response.ok, let result = response.createResult else {
            throw PortpalClientError.serverError(response.message ?? "Create request failed.")
        }
        return result
    }

    public func checkTunnel(sshHost: String, localPort: Int) throws -> CheckTunnelResult {
        let request = PortpalRequest(action: .checkTunnel, lookup: TunnelLookup(sshHost: sshHost, localPort: localPort))
        let response = try send(request)
        guard response.ok, let result = response.checkResult else {
            throw PortpalClientError.serverError(response.message ?? "Check request failed.")
        }
        return result
    }

    public func listTunnels() throws -> ServiceSnapshot {
        let request = PortpalRequest(action: .listTunnels)
        let response = try send(request)
        guard response.ok, let snapshot = response.snapshot else {
            throw PortpalClientError.serverError(response.message ?? "List request failed.")
        }
        return snapshot
    }

    public func removeTunnel(named name: String) throws -> RemoveTunnelResult {
        let request = PortpalRequest(action: .removeTunnel, name: name)
        let response = try send(request)
        guard response.ok, let result = response.removeResult else {
            throw PortpalClientError.serverError(response.message ?? "Remove request failed.")
        }
        return result
    }

    private func send(_ request: PortpalRequest) throws -> PortpalResponse {
        try ServiceLauncher.ensureServiceRunning()

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
