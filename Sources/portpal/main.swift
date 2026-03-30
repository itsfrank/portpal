import Foundation
import PortpalCore

private enum CLIError: LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        }
    }
}

private struct ParsedCreate {
    let name: String?
    let sshHost: String
    let localPort: Int
    let remoteHost: String
    let remotePort: Int
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private func printJSON<T: Encodable>(_ value: T) throws {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func usage() -> String {
    """
    Usage:
      portpal create --host <sshHost> --local-port <port> --remote-host <host> --remote-port <port> [--name <name>]
      portpal check --host <sshHost> --local-port <port>
    """
}

private func parseCreate(arguments: ArraySlice<String>) throws -> ParsedCreate {
    var values: [String: String] = [:]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        guard argument.hasPrefix("--"), let value = iterator.next() else {
            throw CLIError.invalidArguments(usage())
        }
        values[String(argument.dropFirst(2))] = value
    }

    guard let sshHost = values["host"],
          let localPortRaw = values["local-port"], let localPort = Int(localPortRaw),
          let remoteHost = values["remote-host"],
          let remotePortRaw = values["remote-port"], let remotePort = Int(remotePortRaw) else {
        throw CLIError.invalidArguments(usage())
    }

    return ParsedCreate(
        name: values["name"],
        sshHost: sshHost,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort
    )
}

private func parseCheck(arguments: ArraySlice<String>) throws -> TunnelLookup {
    var values: [String: String] = [:]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        guard argument.hasPrefix("--"), let value = iterator.next() else {
            throw CLIError.invalidArguments(usage())
        }
        values[String(argument.dropFirst(2))] = value
    }

    guard let sshHost = values["host"],
          let localPortRaw = values["local-port"], let localPort = Int(localPortRaw) else {
        throw CLIError.invalidArguments(usage())
    }

    return TunnelLookup(sshHost: sshHost, localPort: localPort)
}

do {
    let arguments = CommandLine.arguments.dropFirst()
    guard let command = arguments.first else {
        throw CLIError.invalidArguments(usage())
    }

    let client = PortpalClient()

    switch command {
    case "create":
        let parsed = try parseCreate(arguments: arguments.dropFirst())
        let spec = TunnelSpec(
            name: parsed.name,
            sshHost: parsed.sshHost,
            localPort: parsed.localPort,
            remoteHost: parsed.remoteHost,
            remotePort: parsed.remotePort
        )
        try printJSON(client.createTunnel(spec))
    case "check":
        let lookup = try parseCheck(arguments: arguments.dropFirst())
        let result = try client.checkTunnel(sshHost: lookup.sshHost, localPort: lookup.localPort)
        try printJSON(result)
        exit(result.managed && result.healthy ? 0 : 1)
    default:
        throw CLIError.invalidArguments(usage())
    }
} catch {
    let response = PortpalResponse(ok: false, message: error.localizedDescription)
    try? printJSON(response)
    exit(1)
}
