import Foundation

public enum PortpalEnvironment {
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Portpal", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var configDirectory: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("portpal", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var socketURL: URL {
        configDirectory.appendingPathComponent("portpal.sock")
    }

    public static var stateURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.toml")
    }
}
