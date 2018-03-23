// swift-tools-version:4.0

import PackageDescription

let package = Package(
    name: "LocalizedStrings",
    dependencies: [
        .package(url: "https://github.com/apple/swift-package-manager.git", from: "0.2.0"),
    ],
    targets: [
        .target(name: "LocalizedStrings", dependencies: ["Utility"]),
       .testTarget(name: "LocalizedStringsTests", dependencies: ["LocalizedStrings"]),
    ]
)
