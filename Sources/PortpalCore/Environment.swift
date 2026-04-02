import Foundation

public enum PortpalEnvironment {
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
        applicationSupportDirectory.appendingPathComponent("config.toml")
    }
}
