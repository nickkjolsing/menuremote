// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuRemote",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "MenuRemote",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MenuRemote",
            exclude: ["Resources"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
