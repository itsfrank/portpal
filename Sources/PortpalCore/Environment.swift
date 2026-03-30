import Foundation

public enum PortpalEnvironment {
    public static let serviceName = "PortpalService"

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Portpal", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var socketURL: URL {
        applicationSupportDirectory.appendingPathComponent("portpal.sock")
    }

    public static var stateURL: URL {
        applicationSupportDirectory.appendingPathComponent("tunnels.json")
    }
}

public enum ServiceLauncher {
    public static func ensureServiceRunning() throws {
        if FileManager.default.fileExists(atPath: PortpalEnvironment.socketURL.path) {
            return
        }

        let executableName = PortpalEnvironment.serviceName
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let serviceURL = currentExecutable.deletingLastPathComponent().appendingPathComponent(executableName)

        guard FileManager.default.isExecutableFile(atPath: serviceURL.path) else {
            throw PortpalClientError.serviceNotFound(serviceURL.path)
        }

        let process = Process()
        process.executableURL = serviceURL
        process.arguments = ["serve"]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: PortpalEnvironment.socketURL.path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw PortpalClientError.serviceDidNotStart
    }
}
