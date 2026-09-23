// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EcobeeMac",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "EcobeeMac", targets: ["EcobeeMac"])],
    targets: [
        .target(name: "LocalCore"),
        .executableTarget(name: "EcobeeMac", dependencies: ["LocalCore"]),
        .executableTarget(name: "LocalCoreChecks", dependencies: ["LocalCore"], path: "Tests/LocalCoreTests")
    ]
)
