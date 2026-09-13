// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdrafinilShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AdrafinilShared", targets: ["AdrafinilShared"]),
    ],
    targets: [
        .target(name: "WakeLeaseProcess", path: "Sources/WakeLeaseProcess"),
        .target(
            name: "AdrafinilShared",
            dependencies: ["WakeLeaseProcess"],
            path: "Sources/AdrafinilShared",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "AdrafinilSharedTests",
            dependencies: ["AdrafinilShared"],
            path: "Tests/AdrafinilSharedTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
    ],
)
