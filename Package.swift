// swift-tools-version: 5.9
// For SourceKit / IDE type resolution only — build with `make`.
import PackageDescription

let package = Package(
    name: "Gheen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Gheen",
            path: "Sources/Gheen"
        )
    ]
)
