// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LaunchGrid",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LaunchGrid",
            path: "Sources/LaunchGrid",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
