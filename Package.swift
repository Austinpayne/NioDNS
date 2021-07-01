// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DNSClient",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "DNSClient",
            targets: ["DNSClient"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/Austinpayne/swift-nio.git", .branch("feature/dgram-pktinfo")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .testTarget(
            name: "DNSClientTests",
            dependencies: ["DNSClient", "NIO"]),
        .target(
            name: "DNSClient",
            dependencies: ["NIO"]
        )
    ]
)
