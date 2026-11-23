// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DontGitStranded",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "DontGitStranded", path: "Sources/DontGitStranded"),
        .testTarget(name: "DontGitStrandedTests", dependencies: ["DontGitStranded"],
                    path: "Tests/DontGitStrandedTests"),
    ],
    swiftLanguageModes: [.v5]
)
