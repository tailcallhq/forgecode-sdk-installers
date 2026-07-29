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
        .binaryTarget(
            name: "Sparkle",
            path: "Vendor/Sparkle/Sparkle.xcframework"
        ),
        .executableTarget(
            name: "ForgeMenuBar",
            dependencies: ["ForgeMenuCore", "Sparkle"],
            path: "Sources/ForgeMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded at Contents/Frameworks by
                // scripts/assemble-app.sh; the executable must search there.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
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
