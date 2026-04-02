// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "portpal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PortpalCore", targets: ["PortpalCore"]),
        .executable(name: "PortpalMenuBar", targets: ["PortpalMenuBar"]),
    ],
    targets: [
        .target(name: "PortpalCore"),
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
