// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Docklet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Docklet",
            path: "Sources/Docklet",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
