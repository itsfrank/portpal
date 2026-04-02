import Foundation
import PortpalCore

enum CLIError: LocalizedError {
    case invalidArguments(String)
    case missingRemoveName

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .missingRemoveName:
            return "portpal rm requires a tunnel name."
        }
    }
}

struct ParsedCreate {
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

private struct CLIOptions {
    let json: Bool
    let command: String
    let commandArguments: [String]
}

private struct HumanCheckResult {
    let text: String
    let exitCode: Int32
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func usage() -> String {
    """
    Usage:
      portpal [--json] create --host <sshHost> (--port <port> | --local-port <port> --remote-port <port>) [--remote-host <host>] [--name <name>]
      portpal [--json] check --host <sshHost> --local-port <port>
      portpal [--json] list
      portpal [--json] rm <name>
    """
}

private func printHuman(_ text: String) {
    FileHandle.standardOutput.write(Data("\(text)\n".utf8))
}

private func printError(_ text: String, json: Bool) {
    if json {
        let response = PortpalResponse(ok: false, message: text)
        try? printJSON(response)
    } else {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }
}

private func parseOptions(arguments: ArraySlice<String>) throws -> CLIOptions {
    var json = false
    var remaining: [String] = []

    for argument in arguments {
        if argument == "--json" {
            json = true
        } else {
            remaining.append(argument)
        }
    }

    guard let command = remaining.first else {
        throw CLIError.invalidArguments(usage())
    }

    return CLIOptions(json: json, command: command, commandArguments: Array(remaining.dropFirst()))
}

func parseCreate(arguments: [String]) throws -> ParsedCreate {
    var values: [String: String] = [:]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        guard argument.hasPrefix("--"), let value = iterator.next() else {
            throw CLIError.invalidArguments(usage())
        }
        values[String(argument.dropFirst(2))] = value
    }

    guard let sshHost = values["host"] else {
        throw CLIError.invalidArguments(usage())
    }

    let localPortRaw = values["local-port"] ?? values["port"]
    let remotePortRaw = values["remote-port"] ?? values["port"]
    guard let localPortRaw, let localPort = Int(localPortRaw),
          let remotePortRaw, let remotePort = Int(remotePortRaw) else {
        throw CLIError.invalidArguments(usage())
    }

    let remoteHost = values["remote-host"] ?? "127.0.0.1"

    return ParsedCreate(
        name: values["name"],
        sshHost: sshHost,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort
    )
}

private func parseCheck(arguments: [String]) throws -> TunnelLookup {
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

private func parseRemove(arguments: [String]) throws -> String {
    guard arguments.count == 1 else {
        throw CLIError.missingRemoveName
    }
    return arguments[0]
}

private func renderCreate(_ result: CreateTunnelResult) -> String {
    let subject = result.status.spec.displayName
    let state = result.status.health == .healthy ? "healthy" : "unhealthy"
    return "Created tunnel \(subject) (status: \(state))."
}

private func renderCheck(_ result: CheckTunnelResult, lookup: TunnelLookup) -> HumanCheckResult {
    guard result.managed, let status = result.status else {
        return HumanCheckResult(text: "No managed tunnel found for \(lookup.sshHost):\(lookup.localPort).", exitCode: 1)
    }

    let subject = status.spec.displayName
    if result.healthy {
        return HumanCheckResult(text: "\(subject) is healthy.", exitCode: 0)
    }

    return HumanCheckResult(
        text: "\(subject) is unhealthy (process alive: \(result.processAlive ? "yes" : "no"), port reachable: \(result.portReachable ? "yes" : "no")).",
        exitCode: 1
    )
}

private func renderList(_ snapshot: ServiceSnapshot) -> String {
    guard !snapshot.tunnels.isEmpty else {
        return "No managed tunnels."
    }

    return snapshot.tunnels.map { status in
        let health = status.health == .healthy ? "healthy" : "unhealthy"
        return "\(health)  \(status.spec.displayName)  \(status.spec.sshHost)  \(status.spec.localPort) -> \(status.spec.remoteHost):\(status.spec.remotePort)"
    }.joined(separator: "\n")
}

private func renderRemove(_ result: RemoveTunnelResult) -> HumanCheckResult {
    guard result.removed, let status = result.status else {
        return HumanCheckResult(text: "No managed tunnel found for \(result.name).", exitCode: 1)
    }

    return HumanCheckResult(text: "Removed tunnel \(status.spec.displayName).", exitCode: 0)
}

do {
    let options = try parseOptions(arguments: CommandLine.arguments.dropFirst())

    let client = PortpalClient()

    switch options.command {
    case "create":
        let parsed = try parseCreate(arguments: options.commandArguments)
        let spec = TunnelSpec(
            name: parsed.name,
            sshHost: parsed.sshHost,
            localPort: parsed.localPort,
            remoteHost: parsed.remoteHost,
            remotePort: parsed.remotePort
        )
        let result = try client.createTunnel(spec)
        if options.json {
            try printJSON(result)
        } else {
            printHuman(renderCreate(result))
        }
    case "check":
        let lookup = try parseCheck(arguments: options.commandArguments)
        let result = try client.checkTunnel(sshHost: lookup.sshHost, localPort: lookup.localPort)
        if options.json {
            try printJSON(result)
            exit(result.managed && result.healthy ? 0 : 1)
        } else {
            let rendered = renderCheck(result, lookup: lookup)
            printHuman(rendered.text)
            exit(rendered.exitCode)
        }
    case "list":
        let snapshot = try client.listTunnels()
        if options.json {
            try printJSON(snapshot)
        } else {
            printHuman(renderList(snapshot))
        }
    case "rm":
        let name = try parseRemove(arguments: options.commandArguments)
        let result = try client.removeTunnel(named: name)
        if options.json {
            try printJSON(result)
            exit(result.removed ? 0 : 1)
        } else {
            let rendered = renderRemove(result)
            printHuman(rendered.text)
            exit(rendered.exitCode)
        }
    default:
        throw CLIError.invalidArguments(usage())
    }
} catch {
    let json = CommandLine.arguments.contains("--json")
    printError(error.localizedDescription, json: json)
    exit(1)
}
