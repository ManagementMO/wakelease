// swift-tools-version: 6.0
import PackageDescription

let sourceTesting = Context.environment["WAKELEASE_SOURCE_TESTING"] == "1"
let testDependencies: [Target.Dependency] = sourceTesting
    ? ["AdrafinilShared", .product(name: "Testing", package: "swift-testing")]
    : ["AdrafinilShared"]

let package = Package(
    name: "WakeLease",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "AdrafinilShared", targets: ["AdrafinilShared"]),
        .executable(name: "wakelease", targets: ["WakeLeaseCLI"]),
        .executable(name: "WakeLeaseDaemon", targets: ["WakeLeaseDaemon"]),
        .executable(name: "WakeLeaseHelper", targets: ["WakeLeaseHelper"]),
    ],
    dependencies: sourceTesting ? [
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0"),
    ] : [],
    targets: [
        .target(name: "AdrafinilShared", path: "AdrafinilShared/Sources/AdrafinilShared"),
        .executableTarget(name: "WakeLeaseCLI", dependencies: ["AdrafinilShared"], path: "AdrafinilCLI"),
        .executableTarget(name: "WakeLeaseDaemon", dependencies: ["AdrafinilShared"], path: "AdrafinilDaemon", exclude: ["Info.plist", "LaunchAgent.plist"]),
        .executableTarget(name: "WakeLeaseHelper", dependencies: ["AdrafinilShared"], path: "AdrafinilHelper", exclude: ["Info.plist", "LaunchDaemon.plist"]),
        .testTarget(name: "AdrafinilSharedTests", dependencies: testDependencies, path: "AdrafinilShared/Tests/AdrafinilSharedTests"),
    ],
    swiftLanguageModes: [.v6]
)
