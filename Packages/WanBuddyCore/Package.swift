// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WanBuddyCore",
    products: [
        .library(name: "WanBuddyCore", targets: ["WanBuddyCore"]),
    ],
    targets: [
        .target(
            name: "WanBuddyCore",
            swiftSettings: [
                // Debug builds (Linux `swift test`, and the iOS Debug configuration) include
                // mock repositories. Release builds compile those files out.
                .define("DEV_LOGIN", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "WanBuddyCoreTests",
            dependencies: ["WanBuddyCore"],
            swiftSettings: [
                .define("DEV_LOGIN", .when(configuration: .debug)),
            ]
        ),
    ]
)
