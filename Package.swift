// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProcessMonitor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../StatusItemKit"),
    ],
    targets: [
        .target(name: "ProcessMonitorCore"),
        .executableTarget(
            name: "ProcessMonitor",
            dependencies: ["ProcessMonitorCore", .product(name: "StatusItemKit", package: "StatusItemKit")],
            path: "Sources/ProcessMonitor"
        ),
        .testTarget(name: "ProcessMonitorCoreTests", dependencies: ["ProcessMonitorCore"]),
    ]
)
