// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Longhaul",
    platforms: [.macOS("26.0")],
    products: [.library(name: "LonghaulCore", targets: ["LonghaulCore"]),
               .library(name: "LonghaulBridge", targets: ["LonghaulBridge"]),
               .executable(name: "longhaul", targets: ["LonghaulCLI"]),
               .executable(name: "LonghaulCompanion", targets: ["LonghaulCompanion"])],
    targets: [
        .target(name: "LonghaulCore"),
        .target(name: "CLonghaulSupport"),
        .target(name: "LonghaulBridge", dependencies: ["LonghaulCore", "CLonghaulSupport"]),
        .executableTarget(name: "LonghaulCompanion", dependencies: ["LonghaulBridge"]),
        .executableTarget(name: "LonghaulCLI", dependencies: ["LonghaulCore", "LonghaulBridge"]),
        .testTarget(name: "LonghaulCoreTests", dependencies: ["LonghaulCore", "LonghaulBridge"])
    ]
)
