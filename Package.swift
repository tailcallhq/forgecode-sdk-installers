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
    targets: [
        .target(
            name: "ForgeMenuCore",
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
