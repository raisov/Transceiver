// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Transceiver",
    platforms: [.macOS(.v11), .iOS(.v13)],
    products: [
        .library(
            name: "Transceiver",
            targets: ["Transceiver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/raisov/Interfaces.git", branch: "main")
    ],
    targets: [
        .target(
            name: "Transceiver", dependencies: ["Interfaces"]),

    ]
)
