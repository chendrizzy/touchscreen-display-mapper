// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TouchscreenDisplayMapper",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "touchscreen-display-mapper", targets: ["TouchscreenDisplayMapper"]),
    ],
    targets: [
        .target(name: "TouchMapperCore"),
        .executableTarget(name: "TouchscreenDisplayMapper", dependencies: ["TouchMapperCore"]),
        .testTarget(name: "TouchMapperCoreTests", dependencies: ["TouchMapperCore"]),
    ]
)
