import Darwin
import Dispatch
import Foundation
import PortpalCore

private struct PersistedState: Codable {
    let tunnels: [TunnelSpec]
}

private extension NSLock {
    func withCriticalSection<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class ManagedTunnel {
    let spec: TunnelSpec
    var process: Process?
    var processID: Int32?
    var processAlive = false
    var portReachable = false
    var lastCheckedAt: Date?

    init(spec: TunnelSpec) {
        self.spec = spec
    }

    var status: TunnelStatus {
        TunnelStatus(
            spec: spec,
            isManaged: true,
            processID: processID,
            processAlive: processAlive,
            portReachable: portReachable,
            lastCheckedAt: lastCheckedAt
        )
    }
}

private final class TunnelStore {
    private var tunnelsByID: [UUID: ManagedTunnel] = [:]
    private let stateLock = NSLock()
    private let timerQueue = DispatchQueue(label: "portpal.service.store")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var timer: DispatchSourceTimer?

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadPersistedTunnels()
        startPersistedTunnels()
        startHealthChecks()
    }

    func create(_ spec: TunnelSpec) throws -> CreateTunnelResult {
        try stateLock.withCriticalSection {
            try spec.validate()

            if tunnelsByID.values.contains(where: { $0.spec.sshHost == spec.sshHost && $0.spec.localPort == spec.localPort }) {
                throw TunnelValidationError.duplicateTunnel(spec.sshHost, spec.localPort)
            }

            let managed = ManagedTunnel(spec: spec)
            tunnelsByID[spec.id] = managed
            try startProcess(for: managed)
            refreshHealth(for: managed)
            try persistState()

            return CreateTunnelResult(created: true, started: managed.processAlive, status: managed.status)
        }
    }

    func check(lookup: TunnelLookup) -> CheckTunnelResult {
        stateLock.withCriticalSection {
            guard let tunnel = tunnelsByID.values.first(where: { $0.spec.sshHost == lookup.sshHost && $0.spec.localPort == lookup.localPort }) else {
                return CheckTunnelResult(managed: false, healthy: false, processAlive: false, portReachable: false, status: nil)
            }
            refreshHealth(for: tunnel)
            let status = tunnel.status
            return CheckTunnelResult(
                managed: true,
                healthy: status.health == .healthy,
                processAlive: status.processAlive,
                portReachable: status.portReachable,
                status: status
            )
        }
    }

    func snapshot() -> ServiceSnapshot {
        stateLock.withCriticalSection {
            refreshHealth()
            return ServiceSnapshot(tunnels: tunnelsByID.values.map(\.status))
        }
    }

    private func loadPersistedTunnels() {
        guard let data = try? Data(contentsOf: PortpalEnvironment.stateURL),
              let state = try? decoder.decode(PersistedState.self, from: data) else {
            return
        }

        for spec in state.tunnels {
            tunnelsByID[spec.id] = ManagedTunnel(spec: spec)
        }
    }

    private func startPersistedTunnels() {
        stateLock.withCriticalSection {
            for tunnel in tunnelsByID.values {
                try? startProcess(for: tunnel)
                refreshHealth(for: tunnel)
            }
        }
    }

    private func persistState() throws {
        let specs = tunnelsByID.values.map(\.spec).sorted { $0.displayName < $1.displayName }
        let data = try encoder.encode(PersistedState(tunnels: specs))
        try data.write(to: PortpalEnvironment.stateURL, options: .atomic)
    }

    private func startProcess(for tunnel: ManagedTunnel) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(tunnel.spec.localPort):\(tunnel.spec.remoteHost):\(tunnel.spec.remotePort)",
            tunnel.spec.sshHost,
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()

        tunnel.process = process
        tunnel.processID = process.processIdentifier
        tunnel.processAlive = ProcessHealth.isAlive(pid: process.processIdentifier)
    }

    private func startHealthChecks() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.stateLock.withCriticalSection {
                self?.refreshHealth()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func refreshHealth() {
        for tunnel in tunnelsByID.values {
            refreshHealth(for: tunnel)
        }
    }

    private func refreshHealth(for tunnel: ManagedTunnel) {
        tunnel.processAlive = ProcessHealth.isAlive(pid: tunnel.processID)
        tunnel.portReachable = tunnel.processAlive && PortHealth.canReachLocalPort(tunnel.spec.localPort)
        tunnel.lastCheckedAt = Date()
    }
}

private final class UnixSocketServer {
    private let store: TunnelStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: TunnelStore) {
        self.store = store
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func run() throws {
        let path = PortpalEnvironment.socketURL.path
        unlink(path)

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw PortpalClientError.socketCreateFailed
        }
        defer {
            close(serverFD)
            unlink(path)
        }

        var (address, length) = try SocketSupport.makeUnixAddress(for: path)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, length)
            }
        }
        guard bindResult == 0 else {
            throw PortpalClientError.socketConnectFailed(path)
        }

        guard listen(serverFD, 16) == 0 else {
            throw PortpalClientError.socketConnectFailed(path)
        }

        while true {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                continue
            }
            handleConnection(clientFD)
            close(clientFD)
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        do {
            let requestData = try readAll(from: clientFD)
            let request = try decoder.decode(PortpalRequest.self, from: requestData)
            let response = try handleRequest(request)
            let data = try encoder.encode(response)
            _ = data.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
        } catch {
            let response = PortpalResponse(ok: false, message: error.localizedDescription)
            if let data = try? encoder.encode(response) {
                _ = data.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
            }
        }
    }

    private func handleRequest(_ request: PortpalRequest) throws -> PortpalResponse {
        switch request.action {
        case .createTunnel:
            guard let tunnel = request.tunnel else {
                return PortpalResponse(ok: false, message: "Missing tunnel definition.")
            }
            let result = try store.create(tunnel)
            return PortpalResponse(ok: true, createResult: result)
        case .checkTunnel:
            guard let lookup = request.lookup else {
                return PortpalResponse(ok: false, message: "Missing tunnel lookup.")
            }
            let result = store.check(lookup: lookup)
            return PortpalResponse(ok: true, checkResult: result)
        case .listTunnels:
            return PortpalResponse(ok: true, snapshot: store.snapshot())
        }
    }

    private func readAll(from fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                throw PortpalClientError.socketReadFailed
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "serve"
guard command == "serve" else {
    FileHandle.standardError.write(Data("Usage: PortpalService serve\n".utf8))
    exit(1)
}

private let store = TunnelStore()
private let server = UnixSocketServer(store: store)

do {
    try server.run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
