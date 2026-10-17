// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftwardenCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SwiftwardenCore", targets: ["SwiftwardenCore"])],
    targets: [
        .target(
            name: "SwiftwardenCore",
            path: "Core/Sources/SwiftwardenCore",
            resources: [.copy("Resources/wordlist.txt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SwiftwardenCoreTests",
            dependencies: ["SwiftwardenCore"],
            path: "Core/Tests/SwiftwardenCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
