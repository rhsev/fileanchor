// swift-tools-version: 5.9
import PackageDescription

// No test target on purpose: a machine with only the Command Line Tools ships
// neither XCTest nor swift-testing, so a `.testTarget` reports success without
// running anything — `swift test` printed "Build complete!" and ran zero checks.
// The checks live in a plain executable instead — `swift run fileanchor-selftest`
// — which needs no framework at all. If Xcode ever gets installed, converting it
// back is mechanical.
// The manifest stays at the repository root and the code lives in macos/: a
// SwiftPM dependency is looked up at the root of the repository it names, so
// adlibitum, which depends on FileAnchorKit that way, would not find it
// anywhere else. The Linux engine sits beside it in linux/ with its own
// manifest here at the root.
let package = Package(
    name: "fileanchor",
    platforms: [.macOS(.v13)],
    products: [
        // The macOS engine binary. The wire protocol is OS-neutral; the Linux
        // engine follows the same specification (SPEC.md, PLATFORMS.md).
        .executable(name: "fileanchor", targets: ["fileanchor"]),
        .library(name: "FileAnchorKit", targets: ["FileAnchorKit"]),
    ],
    targets: [
        // All engine logic lives in the library so it is checkable without the
        // stdio shell. The executable is a thin stdin→engine→stdout loop.
        .target(name: "FileAnchorKit", path: "macos/Sources/FileAnchorKit"),
        .executableTarget(name: "fileanchor", dependencies: ["FileAnchorKit"], path: "macos/Sources/fileanchor"),
        .executableTarget(name: "fileanchor-selftest", dependencies: ["FileAnchorKit"], path: "macos/Sources/fileanchor-selftest"),
    ]
)
