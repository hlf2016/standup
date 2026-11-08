// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Standup",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Standup", targets: ["StartupManager"])],
    targets: [.executableTarget(name: "StartupManager")]
)
