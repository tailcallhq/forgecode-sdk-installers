// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForgeMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ForgeMenuCore", targets: ["ForgeMenuCore"]),
        .executable(name: "ForgeMenuBar", targets: ["ForgeMenuBar"]),
        .executable(name: "ForgeRuntimeSmokeHelper", targets: ["ForgeRuntimeSmokeHelper"]),
        .executable(name: "ForgeRuntimeLeaseTestHelper", targets: ["ForgeRuntimeLeaseTestHelper"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ForgeMenuCore",
            dependencies: [],
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
        .executableTarget(
            name: "ForgeRuntimeSmokeHelper",
            dependencies: ["ForgeMenuCore"],
            path: "Sources/ForgeRuntimeSmokeHelper"
        ),
        .executableTarget(
            name: "ForgeRuntimeLeaseTestHelper",
            dependencies: ["ForgeMenuCore"],
            path: "Sources/ForgeRuntimeLeaseTestHelper"
        ),
        .testTarget(
            name: "ForgeMenuCoreTests",
            dependencies: ["ForgeMenuCore"],
            path: "Tests/ForgeMenuCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
