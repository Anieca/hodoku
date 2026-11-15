// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Hodoku",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Hodoku",
            path: "Sources/Hodoku",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
