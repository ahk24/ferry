// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v14)],
    targets: [
        // Quick Share protocol: discovery, UKEY2 handshake, encryption, transfers. No UI, no dependencies.
        .target(name: "FerryCore", path: "Sources/FerryCore"),
        // The menu bar app.
        .executableTarget(name: "Ferry", dependencies: ["FerryCore"], path: "Sources/Ferry"),
        // Offline checks plus a full loopback transfer between two in-process endpoints.
        .executableTarget(name: "ferry-selftest", dependencies: ["FerryCore"], path: "Sources/ferry-selftest"),
    ]
)
