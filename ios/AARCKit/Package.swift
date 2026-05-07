// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AARCKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "AARCKit", targets: ["AARCKit"]),
    ],
    targets: [
        .target(
            name: "AARCKit",
            path: "Sources/AARCKit"
        ),
        .testTarget(
            name: "AARCKitTests",
            dependencies: ["AARCKit"],
            path: "Tests/AARCKitTests"
        ),
    ]
)
