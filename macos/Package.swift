// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForgeMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ForgeMenuCore", targets: ["ForgeMenuCore"]),
        .executable(name: "ForgeMenuBar", targets: ["ForgeMenuBar"])
    ],
    dependencies: [
        // Semantic version parsing and comparison, mirroring the `semver`
        // crate the SDK uses in svc-update. This is SwiftPM's own
        // Version.swift extracted as a standalone package, so it matches the
        // semantics Swift tooling already applies. Apache-2.0, like this repo.
        .package(url: "https://github.com/mxcl/Version.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "ForgeMenuCore",
            dependencies: [
                .product(name: "Version", package: "Version")
            ],
            path: "Sources/ForgeMenuCore"
        ),
        .executableTarget(
            name: "ForgeMenuBar",
            dependencies: ["ForgeMenuCore"],
            path: "Sources/ForgeMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "ForgeMenuCoreTests",
            dependencies: ["ForgeMenuCore"],
            path: "Tests/ForgeMenuCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
