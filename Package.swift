// swift-tools-version: 5.9
import PackageDescription

// No test target on purpose: a machine with only the Command Line Tools ships
// neither XCTest nor swift-testing, so a `.testTarget` reports success without
// running anything — `swift test` printed "Build complete!" and ran zero checks.
// The checks live in a plain executable instead — `swift run fileanchor-selftest`
// — which needs no framework at all. If Xcode ever gets installed, converting it
// back is mechanical.
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
        // All engine logic lives in the library so it is checkable without the
        // stdio shell. The executable is a thin stdin→engine→stdout loop.
        .target(name: "FileAnchorKit"),
        .executableTarget(name: "fileanchor", dependencies: ["FileAnchorKit"]),
        .executableTarget(name: "fileanchor-selftest", dependencies: ["FileAnchorKit"]),
    ]
)
