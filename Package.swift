// swift-tools-version: 6.0
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"])
]

let package = Package(
    name: "GhostDrop",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0")
    ],
    products: [
        .library(name: "GhostDropKit", targets: ["GhostDropKit"])
    ],
    targets: [
        .target(
            name: "GhostDropKit",
            path: "Sources/GhostDropKit",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "GhostDropKitTests",
            dependencies: ["GhostDropKit"],
            path: "Tests/GhostDropKitTests",
            swiftSettings: strictConcurrency
        )
    ],
    swiftLanguageModes: [.v6]
)
