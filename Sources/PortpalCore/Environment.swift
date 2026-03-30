import Foundation

public enum PortpalEnvironment {
    public static let serviceName = "PortpalService"
    public static let servicePathEnvironmentVariable = "PORTPAL_SERVICE_PATH"

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
    public static func resolvedServiceURL() throws -> URL {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment[PortpalEnvironment.servicePathEnvironmentVariable],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        for candidate in candidateServiceURLs() where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw PortpalClientError.serviceNotFound(
            candidateServiceURLs().map(\.path).joined(separator: ", ")
        )
    }

    public static func ensureServiceRunning() throws {
        if FileManager.default.fileExists(atPath: PortpalEnvironment.socketURL.path) {
            return
        }

        let serviceURL = try resolvedServiceURL()

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

    private static func candidateServiceURLs() -> [URL] {
        var candidates: [URL] = []

        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let executableDirectory = currentExecutable.deletingLastPathComponent()

        candidates.append(executableDirectory.appendingPathComponent(PortpalEnvironment.serviceName))

        if let bundleURL = Bundle.main.bundleURL.standardizedFileURLIfBundle {
            candidates.append(bundleURL.appendingPathComponent("Contents/Resources/\(PortpalEnvironment.serviceName)"))
            candidates.append(bundleURL.appendingPathComponent("Contents/MacOS/\(PortpalEnvironment.serviceName)"))
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(PortpalEnvironment.serviceName))
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/libexec/Portpal/\(PortpalEnvironment.serviceName)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/libexec/Portpal/\(PortpalEnvironment.serviceName)"))

        return unique(candidates)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted
        }
    }
}

private extension URL {
    var standardizedFileURLIfBundle: URL? {
        let standardized = standardizedFileURL
        return standardized.pathExtension == "app" ? standardized : nil
    }
}
