// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHRemoteKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DSHRemoteKit", targets: ["DSHRemoteKit"]),
    ],
    targets: [
        .target(
            name: "DSHRemoteKit",
            exclude: ["README.md"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHRemoteKitTests",
            dependencies: ["DSHRemoteKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
