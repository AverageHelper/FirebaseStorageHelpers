// swift-tools-version:5.2

import PackageDescription

let package = Package(
    name: "FirebaseStorageHelpers",
    products: [
        .library(
            name: "FirebaseStorageHelpers",
            targets: ["FirebaseStorageHelpers"]),
    ],
    dependencies: [
        .package(name: "CloudStorage", url: "https://github.com/AverageHelper/CloudStorage.git", .upToNextMinor(from: "0.1.0")),
        // Also Firebase
    ],
    targets: [
        .target(
            name: "FirebaseStorageHelpers",
            dependencies: ["CloudStorage"]),
        .testTarget(
            name: "FirebaseStorageHelpersTests",
            dependencies: ["FirebaseStorageHelpers"]),
    ]
)
