// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuRemote",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MenuRemote",
            path: "Sources/MenuRemote",
            exclude: ["Resources"]
        ),
    ]
)
