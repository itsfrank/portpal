// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "portpal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PortpalCore", targets: ["PortpalCore"]),
        .executable(name: "PortpalService", targets: ["PortpalService"]),
        .executable(name: "portpal", targets: ["portpal"]),
        .executable(name: "PortpalMenuBar", targets: ["PortpalMenuBar"]),
    ],
    targets: [
        .target(name: "PortpalCore"),
        .executableTarget(
            name: "PortpalService",
            dependencies: ["PortpalCore"]
        ),
        .executableTarget(
            name: "portpal",
            dependencies: ["PortpalCore"]
        ),
        .executableTarget(
            name: "PortpalMenuBar",
            dependencies: ["PortpalCore"]
        ),
        .testTarget(
            name: "PortpalCoreTests",
            dependencies: ["PortpalCore"]
        ),
    ]
)
