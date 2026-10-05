// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlurAction",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BlurAction", targets: ["BlurAction"])
    ],
    targets: [
        .target(
            name: "BlurActionMediaSafety",
            path: "Sources/BlurActionMediaSafety",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "BlurAction",
            dependencies: ["BlurActionMediaSafety"],
            path: "Sources/BlurAction"
        ),
        .testTarget(name: "BlurActionTests", dependencies: ["BlurAction", "BlurActionMediaSafety"], path: "Tests/BlurActionTests")
    ]
)
