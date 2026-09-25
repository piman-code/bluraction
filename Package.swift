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
        .executableTarget(
            name: "BlurAction",
            path: "Sources/BlurAction"
        ),
        .testTarget(name: "BlurActionTests", dependencies: ["BlurAction"], path: "Tests/BlurActionTests")
    ]
)