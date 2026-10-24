// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TabWM",
    // A string: the `.v15` constant needs tools version 6.0, which would also switch the
    // package to Swift 6 language mode.
    platforms: [.macOS("15.0")],
    products: [.executable(name: "TabWM", targets: ["TabWM"])],
    targets: [
        .target(name: "TabWMCore"),
        .executableTarget(name: "TabWM", dependencies: ["TabWMCore"]),
        .testTarget(name: "TabWMCoreTests", dependencies: ["TabWMCore"])
    ]
)
