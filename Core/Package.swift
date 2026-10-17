// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftwardenCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SwiftwardenCore", targets: ["SwiftwardenCore"])],
    targets: [
        .target(
            name: "SwiftwardenCore",
            resources: [.copy("Resources/wordlist.txt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SwiftwardenCoreTests",
            dependencies: ["SwiftwardenCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
