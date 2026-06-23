// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MacNotchKiller",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacNotchKiller", targets: ["MacNotchKiller"])
    ],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "MacNotchKiller",
            dependencies: ["VirtualDisplayBridge"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
