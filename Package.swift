// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "fileanchor",
    platforms: [.macOS(.v13)],
    products: [
        // The engine binary. macOS implementation today; the wire protocol is
        // OS-neutral, so a Linux implementation can live alongside it later.
        .executable(name: "fileanchor", targets: ["fileanchor"]),
        .library(name: "FileAnchorKit", targets: ["FileAnchorKit"]),
    ],
    targets: [
        // All engine logic lives in the library so it is unit-testable without
        // the stdio shell. The executable is a thin stdin→engine→stdout loop.
        .target(name: "FileAnchorKit"),
        .executableTarget(name: "fileanchor", dependencies: ["FileAnchorKit"]),
        .testTarget(name: "FileAnchorKitTests", dependencies: ["FileAnchorKit"]),
    ]
)
